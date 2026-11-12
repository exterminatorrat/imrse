import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct SelectedTextReplacementConfirmationTests {
    private let replacementRange = ImrseCore.TextRange(location: 4, length: 3)
    private let replacement = "new"
    private let expectedValue = "abc new xyz"

    @Test
    func exactWholeValueReadbackConfirmsApplied() {
        #expect(confirmsSelectedReplacement(expectedValue: expectedValue, afterValue: expectedValue))
    }

    @Test(arguments: [nil, "abc old xyz", "abd new xyz", "abc new xyz "] as [String?])
    func wholeValueExpectationRequiresExactReadback(afterValue: String?) {
        #expect(!confirmsSelectedReplacement(expectedValue: expectedValue, afterValue: afterValue))
    }

    @Test
    func canonicallyEquivalentReadbackIsNotAnExactReceipt() {
        let precomposed = "caf\u{00E9} new"
        let decomposed = "cafe\u{0301} new"

        #expect(precomposed.precomposedStringWithCanonicalMapping == decomposed.precomposedStringWithCanonicalMapping)
        #expect(!precomposed.utf16.elementsEqual(decomposed.utf16))
        #expect(!confirmsSelectedReplacement(expectedValue: precomposed, afterValue: decomposed))
    }

    @Test
    func rangeOnlyEvidenceStillConfirmsWithoutWholeValueProof() {
        #expect(confirmsSelectedReplacement(expectedValue: nil, afterValue: nil))
        #expect(confirmsSelectedReplacement(expectedValue: nil, afterValue: "abc old xyz"))
        #expect(!confirmsSelectedReplacement(
            expectedValue: nil,
            afterValue: nil,
            afterRange: ImrseCore.TextRange(location: 5, length: 3)
        ))
        #expect(!confirmsSelectedReplacement(expectedValue: nil, afterValue: nil, afterText: "old"))
    }

    @Test
    func collapsedCaretFallbackStaysRangeOnlyWithoutWholeValueProof() {
        let caret = ImrseCore.TextRange(location: 7, length: 0)

        #expect(UTF16SelectionRange.isCollapsedCaret(caret, selectedText: "", atEndOf: replacementRange))
        #expect(SelectedTextReplacementValidation.permitsRangeOnlyConfirmation(expectedValue: nil))
        #expect(!SelectedTextReplacementValidation.permitsRangeOnlyConfirmation(expectedValue: expectedValue))
        #expect(!confirmsSelectedReplacement(
            expectedValue: expectedValue,
            afterValue: nil,
            afterRange: caret,
            afterText: ""
        ))
    }

    @Test(arguments: [nil, "abc old xyz", "abd new xyz"] as [String?])
    func uncertainReadbackYieldsNoReceiptAndNoFurtherTransport(afterValue: String?) {
        let confirmed = confirmsSelectedReplacement(expectedValue: expectedValue, afterValue: afterValue)
        let outcome: SelectionMutationOutcome<String> = confirmed
            ? .confirmedApplied("receipt")
            : .indeterminate(.replacementEvidenceMismatch)

        guard case let .indeterminate(reason) = outcome else {
            Issue.record("A disagreeing or missing whole-value readback must not produce a receipt")
            return
        }
        #expect(reason == .replacementEvidenceMismatch)
        #expect(!outcome.allowsFallback)
    }

    private func confirmsSelectedReplacement(
        expectedValue: String?,
        afterValue: String?,
        afterRange: ImrseCore.TextRange? = nil,
        afterText: String = "new"
    ) -> Bool {
        SelectedTextReplacementValidation.confirms(
            afterValue: afterValue,
            expectedValue: expectedValue,
            afterRange: afterRange ?? replacementRange,
            afterText: afterText,
            replacementRange: replacementRange,
            replacement: replacement
        )
    }
}
