import Foundation
import CoreFoundation
import ImrseCore

enum ResponseMetadataParser {
    static func parse(
        model: Any?,
        inputTokens: Any?,
        outputTokens: Any?,
        totalTokens: Any?,
        costUSD: Any?
    ) -> ResponseMetadata? {
        let metadata = ResponseMetadata(
            detectedModel: modelValue(model),
            inputTokens: tokenCount(inputTokens),
            outputTokens: tokenCount(outputTokens),
            totalTokens: tokenCount(totalTokens),
            costUSD: costValue(costUSD)
        )
        guard metadata.detectedModel != nil || metadata.inputTokens != nil || metadata.outputTokens != nil
                || metadata.totalTokens != nil || metadata.costUSD != nil
        else { return nil }
        return metadata
    }

    private static func modelValue(_ value: Any?) -> String? {
        guard let model = value as? String,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 256,
              model.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return model
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }

        if let number = number as? NSDecimalNumber {
            let decimal = number.decimalValue
            guard !decimal.isNaN, decimal >= 0, decimal <= Decimal(Int.max) else { return nil }
            var source = decimal
            var rounded = Decimal()
            NSDecimalRound(&rounded, &source, 0, .plain)
            guard rounded == decimal else { return nil }
            return Int(number.stringValue)
        }

        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            let count = number.int64Value
            guard count >= 0 else { return nil }
            return Int(exactly: count)
        case "C", "S", "I", "L", "Q":
            return Int(exactly: number.uint64Value)
        default:
            let count = number.doubleValue
            guard count.isFinite, count >= 0 else { return nil }
            return Int(exactly: count)
        }
    }

    private static func costValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let cost = number.doubleValue
        guard cost.isFinite, cost >= 0 else { return nil }
        return cost
    }
}
