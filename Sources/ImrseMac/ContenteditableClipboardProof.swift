#if os(macOS)
import Foundation
import ImrseCore

enum ContenteditableClipboardProof {
    case uniform(ContenteditableTextStyleProof)
    case structured(ContenteditableTextStyleProof.Structured)

    var originalText: String {
        switch self {
        case .uniform(let proof): return proof.originalText
        case .structured(let proof): return proof.originalText
        }
    }

    var expectedText: String {
        switch self {
        case .uniform(let proof): return proof.expectedText
        case .structured(let proof): return proof.expectedText
        }
    }

    func inverse(
        selectionRange: ImrseCore.TextRange,
        selectedText: String,
        replacement: String
    ) -> Self? {
        switch self {
        case .uniform(let proof):
            guard let inverse = proof.inverse(
                selectionRange: selectionRange,
                selectedText: selectedText,
                replacement: replacement
            ) else {
                return nil
            }
            return .uniform(inverse)
        case .structured(let proof):
            guard let inverse = proof.inverse(
                selectionRange: selectionRange,
                selectedText: selectedText,
                replacement: replacement
            ) else {
                return nil
            }
            return .structured(inverse)
        }
    }
}
#endif
