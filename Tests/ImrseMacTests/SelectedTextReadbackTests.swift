import ImrseCore
import Testing
@testable import ImrseMac

struct SelectedTextReadbackTests {
    @Test
    func caretInsertionReadsWholeValueWithoutAClipboardBaseline() throws {
        let caret = ImrseCore.TextRange(location: 4, length: 0)
        let baseline = ClipboardFallbackNoOpValidation.baseline(value: "abc xyz", range: caret, selectedText: "")
        #expect(baseline == nil)
        let expectedValue = "abc newxyz"
        var reads = 0

        let afterValue = try SelectedTextReplacementValidation.readbackValue(
            expectedValue: expectedValue,
            fallbackBaseline: baseline,
            read: {
                reads += 1
                return expectedValue
            }
        )

        #expect(reads == 1)
        #expect(SelectedTextReplacementValidation.confirms(
            afterValue: afterValue,
            expectedValue: expectedValue,
            afterRange: ImrseCore.TextRange(location: 7, length: 0),
            afterText: "",
            replacementRange: ImrseCore.TextRange(location: 4, length: 3),
            replacement: "new"
        ))
    }

    @Test
    func requiredWholeValueReadbackDoesNotSwallowFailure() {
        #expect(throws: ImrseError.permissionRequired) {
            _ = try SelectedTextReplacementValidation.readbackValue(
                expectedValue: "abc newxyz",
                fallbackBaseline: "abc xyz",
                read: { throw ImrseError.permissionRequired }
            )
        }
    }

    @Test
    func optionalClipboardReadbackMayBeUnavailable() throws {
        let value = try SelectedTextReplacementValidation.readbackValue(
            expectedValue: nil,
            fallbackBaseline: "abc xyz",
            read: { throw ImrseError.replacementFailed }
        )
        #expect(value == nil)
    }

    @Test
    func rangeOnlyConfirmationDoesNotReadAnUnneededWholeValue() throws {
        var reads = 0
        let value = try SelectedTextReplacementValidation.readbackValue(
            expectedValue: nil,
            fallbackBaseline: nil,
            read: {
                reads += 1
                return "abc xyz"
            }
        )
        #expect(value == nil)
        #expect(reads == 0)
    }
}
