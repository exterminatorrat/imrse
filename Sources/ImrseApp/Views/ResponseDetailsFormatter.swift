#if os(macOS)
import Foundation
import ImrseCore

enum ResponseDetailsFormatter {
    struct Row: Equatable {
        let label: String
        let value: String

        var menuTitle: String { "\(label): \(value)" }
    }

    static func rows(for metadata: ResponseMetadata?) -> [Row] {
        [
            Row(label: "Detected model", value: model(metadata?.detectedModel)),
            Row(label: "Input tokens", value: tokenCount(metadata?.inputTokens)),
            Row(label: "Output tokens", value: tokenCount(metadata?.outputTokens)),
            Row(label: "Total tokens", value: tokenCount(metadata?.totalTokens)),
            Row(label: "Cost (USD)", value: cost(metadata?.costUSD))
        ]
    }

    private static func model(_ value: String?) -> String {
        guard let value else { return "Unavailable" }
        let normalized = value.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "Unavailable" }
        return String(normalized.prefix(128))
    }

    private static func tokenCount(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "Unavailable" }
        return String(value)
    }

    private static func cost(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.positivePrefix = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2

        if value > 0 && value < 0.005 {
            let precision = Int(ceil(-log10(value))) + 1
            if precision <= 15 {
                formatter.maximumFractionDigits = max(2, precision)
            } else {
                let scientificFormatter = NumberFormatter()
                scientificFormatter.numberStyle = .scientific
                scientificFormatter.locale = Locale(identifier: "en_US_POSIX")
                scientificFormatter.maximumSignificantDigits = 6
                guard let formatted = scientificFormatter.string(from: NSNumber(value: value)) else {
                    return "Unavailable"
                }
                return "$\(formatted)"
            }
        }

        return formatter.string(from: NSNumber(value: value)) ?? "Unavailable"
    }
}
#endif
