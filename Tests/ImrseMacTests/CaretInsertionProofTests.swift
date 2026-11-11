#if os(macOS)
import ApplicationServices
import ImrseCore
import Testing
@testable import ImrseMac

struct CaretInsertionProofTests {
    private typealias TextRange = ImrseCore.TextRange

    @Test(arguments: [0, 1, 3, 5])
    func insertionPreservesExactUnicodeContext(at offset: Int) throws {
        let proof = try #require(CaretInsertionProof(
            value: "a😀e\u{301}",
            range: TextRange(location: offset, length: 0),
            selectedText: "",
            permitsPlainTextValueWrite: true,
            composition: .unmarked
        ))
        let expected = try #require(UTF16SelectionRange.replacing(
            proof.value,
            range: proof.range,
            with: "🪻\u{301}"
        ))
        #expect(proof.inserting("🪻\u{301}")?.utf16.elementsEqual(expected.utf16) == true)
        #expect(proof.matches(value: proof.value, range: proof.range, selectedText: ""))
    }

    @Test
    func emptyDocumentIsExplicitlyProvable() throws {
        let proof = try #require(make(value: "", range: TextRange(location: 0, length: 0)))
        #expect(proof.inserting("😀") == "😀")
        #expect(proof.inserting("") == nil)
    }

    @Test
    func absentDocumentSelectionOrPlainTextCapabilityIsRefused() {
        #expect(make(value: nil) == nil)
        #expect(make(selectedText: nil) == nil)
        #expect(make(selectedText: "a") == nil)
        #expect(make(permitsPlainTextValueWrite: false) == nil)
    }

    @Test(arguments: [-1, 2, 6, Int.max])
    func invalidOrSplitSurrogateCaretsAreRefused(at offset: Int) {
        #expect(make(range: TextRange(location: offset, length: 0)) == nil)
    }

    @Test
    func noncollapsedAndOversizeContextsAreRefused() {
        #expect(make(range: TextRange(location: 0, length: 1)) == nil)
        #expect(make(range: TextRange(location: 0, length: -1)) == nil)
        #expect(make(value: String(repeating: "a", count: 65_537)) == nil)
        let maximum = make(value: String(repeating: "a", count: 65_536))
        #expect(maximum != nil)
        #expect(maximum?.inserting("a") == nil)
    }

    @Test
    func exactValueCaretAndEmptySelectionMustRemainBound() throws {
        let proof = try #require(make())
        #expect(!proof.matches(value: nil, range: proof.range, selectedText: ""))
        #expect(!proof.matches(value: "a😀é", range: proof.range, selectedText: ""))
        #expect(!proof.matches(value: "a😀e\u{301}!", range: proof.range, selectedText: ""))
        #expect(!proof.matches(value: proof.value, range: TextRange(location: 1, length: 0), selectedText: ""))
        #expect(!proof.matches(value: proof.value, range: proof.range, selectedText: "a"))
    }

    @Test
    func onlyAdvertisedSuccessfulEmptyMarkedRangeProvesNoComposition() {
        #expect(CaretCompositionState.read(advertised: true, status: .success, hasValue: false) == .unmarked)
        #expect(CaretCompositionState.read(advertised: true, status: .noValue, hasValue: false) == .unmarked)
        #expect(CaretCompositionState.read(advertised: true, status: .success, hasValue: true) == .marked)
        #expect(CaretCompositionState.read(advertised: true, status: .noValue, hasValue: true) == .marked)
        #expect(CaretCompositionState.read(advertised: false, status: .success, hasValue: false) == .unavailable)
        #expect(CaretCompositionState.read(advertised: true, status: .attributeUnsupported, hasValue: false) == .unavailable)
        #expect(CaretCompositionState.read(advertised: true, status: .cannotComplete, hasValue: false) == .unavailable)
        #expect(make(composition: .marked) == nil)
        #expect(make(composition: .unavailable) == nil)
    }

    @Test
    func insertionDoesNotRelaxTheExistingClipboardNoOpGate() {
        #expect(ClipboardFallbackNoOpValidation.baseline(
            value: "a😀e\u{301}",
            range: TextRange(location: 1, length: 0),
            selectedText: ""
        ) == nil)
    }

    @Test(arguments: [0, 1, 3, 5])
    func inverseRestoresOnlyTheExactInsertedDocument(at offset: Int) throws {
        let proof = try #require(make(range: TextRange(location: offset, length: 0)))
        let replacement = "🪻\u{301}"
        let applied = try #require(proof.inserting(replacement))
        let replacementRange = TextRange(location: offset, length: replacement.utf16.count)
        let caret = UndoSelectionProof(
            text: "",
            range: TextRange(location: offset + replacement.utf16.count, length: 0)
        )
        let receipt = ReplacementReceipt(
            target: SelectionSnapshot(
                applicationID: "owned.fixture",
                processID: 42,
                role: "AXTextField",
                text: "",
                range: proof.range,
                isSecure: false,
                intent: .insertAtCaret
            ),
            replacement: replacement,
            strategy: .selectedText
        )
        #expect(proof.confirmsApplied(value: applied, inserting: replacement))
        #expect(!proof.confirmsApplied(value: applied + "!", inserting: replacement))
        #expect(!proof.confirmsApplied(value: nil, inserting: replacement))
        #expect(!proof.confirmsApplied(value: proof.value, inserting: replacement))
        let restored = PlainTextUndoValidation.restoredValue(
            currentValue: applied,
            receipt: receipt,
            replacementRange: replacementRange,
            currentSelection: caret,
            receiptSelection: caret
        )
        #expect(restored?.utf16.elementsEqual(proof.value.utf16) == true)
    }

    @Test(arguments: [0, 1, 3, 5])
    func insertionInverseRequiresTheExactInsertedDocument(at offset: Int) throws {
        let proof = try #require(make(range: TextRange(location: offset, length: 0)))
        let replacement = "🪻\u{301}"
        let applied = try #require(proof.inserting(replacement))
        let receipt = insertionReceipt(proof: proof, replacement: replacement)
        let selection = caret(afterInserting: replacement, at: offset)

        #expect(restored(proof, receipt, applied, selection)?.utf16.elementsEqual(proof.value.utf16) == true)
        #expect(PlainTextUndoValidation.restoredValue(
            currentValue: applied + "!",
            receipt: receipt,
            replacementRange: TextRange(location: offset, length: replacement.utf16.count),
            currentSelection: selection,
            receiptSelection: selection
        ) != nil)
        #expect(restored(proof, receipt, applied + "!", selection) == nil)
        #expect(restored(proof, receipt, "Z" + applied, selection) == nil)
        #expect(restored(proof, receipt, proof.value, selection) == nil)

        let sameLengthEdit = try #require(UTF16SelectionRange.replacing(
            applied,
            range: TextRange(location: offset, length: replacement.utf16.count),
            with: "🪻a"
        ))
        #expect(sameLengthEdit.utf16.count == applied.utf16.count)
        #expect(restored(proof, receipt, sameLengthEdit, selection) == nil)
    }

    @Test
    func canonicalEquivalenceDoesNotConfirmInsertionOrItsInverse() throws {
        let proof = try #require(make(value: "e\u{301}", range: TextRange(location: 0, length: 0)))
        let applied = try #require(proof.inserting("🪻"))
        let composed = "🪻\u{E9}"
        #expect(composed == applied)
        #expect(composed.utf16.count != applied.utf16.count)
        let receipt = insertionReceipt(proof: proof, replacement: "🪻")
        let selection = caret(afterInserting: "🪻", at: 0)

        #expect(!proof.confirmsApplied(value: composed, inserting: "🪻"))
        #expect(restored(proof, receipt, applied, selection) != nil)
        #expect(restored(proof, receipt, composed, selection) == nil)
    }

    @Test
    func insertionInverseRequiresTheReceiptBoundSelection() throws {
        let proof = try #require(make())
        let replacement = "🪻"
        let applied = try #require(proof.inserting(replacement))
        let receipt = insertionReceipt(proof: proof, replacement: replacement)
        let selection = caret(afterInserting: replacement, at: 0)

        #expect(restored(proof, receipt, applied, selection) != nil)
        #expect(restored(
            proof,
            receipt,
            applied,
            UndoSelectionProof(text: "", range: TextRange(location: replacement.utf16.count + 1, length: 0))
        ) == nil)

        let selectedInsertion = UndoSelectionProof(
            text: replacement,
            range: TextRange(location: 0, length: replacement.utf16.count)
        )
        #expect(restored(
            proof,
            receipt,
            applied,
            selectedInsertion,
            receiptSelection: selectedInsertion
        ) != nil)
        #expect(restored(
            proof,
            receipt,
            applied,
            UndoSelectionProof(text: "", range: selectedInsertion.range),
            receiptSelection: selectedInsertion
        ) == nil)
    }

    @Test
    func insertionInverseRejectsReceiptsThatDoNotMatchTheProof() throws {
        let proof = try #require(make())
        let replacement = "🪻"
        let applied = try #require(proof.inserting(replacement))
        let selection = caret(afterInserting: replacement, at: 0)
        let receipt = insertionReceipt(proof: proof, replacement: replacement)

        #expect(restored(proof, replacementReceipt(proof: proof, replacement: replacement), applied, selection) == nil)
        #expect(restored(
            proof,
            insertionReceipt(proof: proof, replacement: replacement, range: TextRange(location: 1, length: 0)),
            applied,
            selection
        ) == nil)
        #expect(restored(
            proof,
            insertionReceipt(proof: proof, replacement: replacement, text: "a"),
            applied,
            selection
        ) == nil)
        #expect(restored(proof, receipt, applied, selection) != nil)
    }

    @Test(arguments: [0, 1, 3, 4])
    func insertionPreservesCJKContextAtEachScalarBoundary(at offset: Int) throws {
        let proof = try #require(make(value: "東😀京", range: TextRange(location: offset, length: 0)))
        let inserted = try #require(proof.inserting("語"))
        let expected = try #require(UTF16SelectionRange.replacing(
            proof.value,
            range: proof.range,
            with: "語"
        ))
        #expect(inserted.utf16.count == 5)
        #expect(inserted.utf16.elementsEqual(expected.utf16))
    }

    @Test
    func caretInsideASurrogatePairIsRefusedInCJKContext() {
        #expect(make(value: "東😀京", range: TextRange(location: 2, length: 0)) == nil)
        #expect(make(value: "東😀京", range: TextRange(location: 3, length: 0)) != nil)
    }

    @Test
    func insertionConfirmationNeverFallsBackToRangeOnlyEvidence() {
        let expected = "🪻a😀e\u{301}"
        let replacementRange = TextRange(location: 0, length: "🪻".utf16.count)

        #expect(!SelectedTextReplacementValidation.permitsRangeOnlyConfirmation(expectedValue: expected))
        #expect(!SelectedTextReplacementValidation.confirms(
            afterValue: nil,
            expectedValue: expected,
            afterRange: replacementRange,
            afterText: "🪻",
            replacementRange: replacementRange,
            replacement: "🪻"
        ))
        #expect(SelectedTextReplacementValidation.permitsRangeOnlyConfirmation(expectedValue: nil))
        #expect(SelectedTextReplacementValidation.confirms(
            afterValue: expected,
            expectedValue: expected,
            afterRange: replacementRange,
            afterText: "🪻",
            replacementRange: replacementRange,
            replacement: "🪻"
        ))
    }

    private func insertionReceipt(
        proof: CaretInsertionProof,
        replacement: String,
        range: TextRange? = nil,
        text: String = "",
        intent: SelectionEditIntent = .insertAtCaret
    ) -> ReplacementReceipt {
        ReplacementReceipt(
            target: SelectionSnapshot(
                applicationID: "owned.fixture",
                processID: 42,
                role: "AXTextField",
                text: text,
                range: range ?? proof.range,
                isSecure: false,
                intent: intent
            ),
            replacement: replacement,
            strategy: .selectedText
        )
    }

    private func replacementReceipt(proof: CaretInsertionProof, replacement: String) -> ReplacementReceipt {
        insertionReceipt(proof: proof, replacement: replacement, intent: .replaceSelection)
    }

    private func caret(afterInserting text: String, at offset: Int) -> UndoSelectionProof {
        UndoSelectionProof(
            text: "",
            range: TextRange(location: offset + text.utf16.count, length: 0)
        )
    }

    private func restored(
        _ proof: CaretInsertionProof,
        _ receipt: ReplacementReceipt,
        _ currentValue: String,
        _ selection: UndoSelectionProof,
        receiptSelection: UndoSelectionProof? = nil
    ) -> String? {
        PlainTextUndoValidation.insertionRestoredValue(
            currentValue: currentValue,
            proof: proof,
            receipt: receipt,
            currentSelection: selection,
            receiptSelection: receiptSelection ?? caret(
                afterInserting: receipt.replacement,
                at: proof.range.location
            )
        )
    }

    private func make(
        value: String? = "a😀e\u{301}",
        range: TextRange = TextRange(location: 0, length: 0),
        selectedText: String? = "",
        permitsPlainTextValueWrite: Bool = true,
        composition: CaretCompositionState = .unmarked
    ) -> CaretInsertionProof? {
        CaretInsertionProof(
            value: value,
            range: range,
            selectedText: selectedText,
            permitsPlainTextValueWrite: permitsPlainTextValueWrite,
            composition: composition
        )
    }
}
#endif
