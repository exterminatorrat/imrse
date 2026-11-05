import CoreGraphics
import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct ContenteditableTextStyleProofTests {
    @Test
    func confirmsImmutableColorsByValueAndRejectsChangedColors() throws {
        let original = styled("target", foreground: CGColor(gray: 0.25, alpha: 1))
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))

        #expect(proof.confirmsOriginal(styled("target", foreground: CGColor(gray: 0.25, alpha: 1))))
        #expect(proof.confirmsApplied(styled("text", foreground: CGColor(gray: 0.25, alpha: 1))))
        #expect(!proof.confirmsApplied(styled("text", foreground: CGColor(gray: 0.5, alpha: 1))))
    }

    @Test
    func provesPartialReplacementAndPreservesEveryAllowedStyle() throws {
        let original = styled("before target after", background: "synthetic background")
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))
        let expected = styled("before replacement after", background: "synthetic background")

        #expect(proof.originalValue.isEqual(to: original))
        #expect(proof.expectedValue.isEqual(to: expected))
        #expect(proof.confirmsApplied(expected))
        #expect(proof.confirmsOriginal(original))
    }

    @Test
    func provesWholeValueSelection() throws {
        let original = styled("whole value")
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: original.length),
            selectedText: original.string,
            replacement: "replaced"
        ))

        #expect(proof.expectedValue.isEqual(to: styled("replaced")))
        #expect(proof.confirmsApplied(proof.expectedValue))
        #expect(proof.confirmsOriginal(original))
    }

    @Test
    func acceptsScalarAlignedUnicodeIncludingACombiningMarkBoundary() throws {
        let selectedText = "😀漢字e\u{301}"
        let original = styled("A\(selectedText)Z")
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 1, length: selectedText.utf16.count),
            selectedText: selectedText,
            replacement: "🚀かな"
        ))

        #expect(proof.expectedValue.string == "A🚀かなZ")
        #expect(proof.confirmsApplied(styled("A🚀かなZ")))

        let decomposed = styled("e\u{301}")
        let combiningMarkProof = try #require(ContenteditableTextStyleProof(
            originalValue: decomposed,
            selectionRange: TextRange(location: 1, length: 1),
            selectedText: "\u{301}",
            replacement: "!"
        ))

        #expect(combiningMarkProof.expectedValue.string == "e!")
    }

    @Test
    func rejectsInvalidRangesAndEmptyInputs() {
        let original = styled("A😀B")

        #expect(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: -1, length: 1),
            selectedText: "A",
            replacement: "x"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: -1),
            selectedText: "",
            replacement: "x"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: Int.max, length: 1),
            selectedText: "A",
            replacement: "x"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 4, length: 1),
            selectedText: "B",
            replacement: "x"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 1, length: 1),
            selectedText: "x",
            replacement: "y"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: 1),
            selectedText: "Z",
            replacement: "x"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: 1),
            selectedText: "A",
            replacement: ""
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: 0),
            selectedText: "",
            replacement: "x"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: styled(""),
            selectionRange: TextRange(location: 0, length: 0),
            selectedText: "",
            replacement: "x"
        ) == nil)
    }

    @Test
    func rejectsCanonicallyEquivalentTextWithDifferentUTF16() throws {
        let originalText = "cafe\u{301} target"
        let prefixLength = "cafe\u{301} ".utf16.count
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: styled(originalText),
            selectionRange: TextRange(location: prefixLength, length: 6),
            selectedText: "target",
            replacement: "result"
        ))
        let canonicallyEquivalentOriginal = styled("café target")
        let canonicallyEquivalentApplied = styled("café result")

        #expect(originalText == canonicallyEquivalentOriginal.string)
        #expect(!originalText.utf16.elementsEqual(canonicallyEquivalentOriginal.string.utf16))
        #expect(!proof.confirmsOriginal(canonicallyEquivalentOriginal))
        #expect(proof.expectedValue.string == canonicallyEquivalentApplied.string)
        #expect(!proof.expectedValue.string.utf16.elementsEqual(canonicallyEquivalentApplied.string.utf16))
        #expect(!proof.confirmsApplied(canonicallyEquivalentApplied))
        #expect(ContenteditableTextStyleProof(
            originalValue: styled("é"),
            selectionRange: TextRange(location: 0, length: 1),
            selectedText: "e\u{301}",
            replacement: "x"
        ) == nil)
    }

    @Test
    func acceptsTheWholeValueUTF16LimitAndRejectsOneUnitMore() throws {
        let maximumLength = ContenteditableTextStyleProof.maximumWholeValueUTF16Length
        #expect(maximumLength == 65_536)

        let atLimit = styled(String(repeating: "x", count: maximumLength))
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: atLimit,
            selectionRange: TextRange(location: maximumLength - 1, length: 1),
            selectedText: "x",
            replacement: "y"
        ))

        #expect(proof.expectedValue.string.utf16.count == maximumLength)
        #expect(proof.confirmsApplied(proof.expectedValue))
        #expect(ContenteditableTextStyleProof(
            originalValue: atLimit,
            selectionRange: TextRange(location: maximumLength - 1, length: 1),
            selectedText: "x",
            replacement: "yy"
        ) == nil)

        let overLimit = styled(String(repeating: "x", count: maximumLength + 1))
        #expect(ContenteditableTextStyleProof(
            originalValue: overLimit,
            selectionRange: TextRange(location: 0, length: 1),
            selectedText: "x",
            replacement: "y"
        ) == nil)
    }

    @Test
    func requiresFontAndForegroundAndRejectsUnknownAttributes() throws {
        let original = styled("target")
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))
        #expect(proof.confirmsApplied(styled("text")))

        #expect(ContenteditableTextStyleProof(
            originalValue: styled("target", font: nil),
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: styled("target", foreground: nil),
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ) == nil)

        let unknownAttributeValue = NSMutableAttributedString(attributedString: styled("before target after"))
        unknownAttributeValue.addAttribute(
            NSAttributedString.Key(rawValue: "AXUnknown"),
            value: "unsupported",
            range: NSRange(location: 14, length: 5)
        )
        #expect(ContenteditableTextStyleProof(
            originalValue: unknownAttributeValue,
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "target",
            replacement: "text"
        ) == nil)
    }

    @Test
    func acceptsAndFreezesFlatFontDictionaries() throws {
        let mutableFont = NSMutableDictionary(dictionary: [
            "family": NSString(string: "synthetic font"),
            "size": NSNumber(value: 12)
        ])
        let original = styled("target", font: mutableFont)
        let fontSnapshot = NSDictionary(dictionary: [
            "family": NSString(string: "synthetic font"),
            "size": NSNumber(value: 12)
        ])
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))

        mutableFont.setObject(NSString(string: "mutated font"), forKey: "family" as NSString)

        #expect(proof.originalValue.isEqual(to: styled("target", font: fontSnapshot)))
        #expect(proof.expectedValue.isEqual(to: styled("replacement", font: fontSnapshot)))
        #expect(proof.confirmsOriginal(styled("target", font: fontSnapshot)))
    }

    @Test
    func freezesMutableNSStringFontAndColorLeaves() throws {
        let expectedFont = "mutable leaf baseline font"
        let expectedForeground = "mutable leaf baseline foreground"
        let expectedBackground = "mutable leaf baseline background"
        let mutableFont = NSMutableString(string: expectedFont)
        let mutableForeground = NSMutableString(string: expectedForeground)
        let mutableBackground = NSMutableString(string: expectedBackground)
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: styled(
                "target",
                font: mutableFont,
                foreground: mutableForeground,
                background: mutableBackground
            ),
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))

        mutableFont.setString("caller changed font")
        mutableForeground.setString("caller changed foreground")
        mutableBackground.setString("caller changed background")

        #expect(proof.confirmsOriginal(styled(
            "target",
            font: expectedFont,
            foreground: expectedForeground,
            background: expectedBackground
        )))
        #expect(proof.confirmsApplied(styled(
            "replacement",
            font: expectedFont,
            foreground: expectedForeground,
            background: expectedBackground
        )))
        #expect(!proof.confirmsOriginal(styled(
            "target",
            font: mutableFont,
            foreground: mutableForeground,
            background: mutableBackground
        )))
        #expect(!proof.confirmsApplied(styled(
            "replacement",
            font: mutableFont,
            foreground: mutableForeground,
            background: mutableBackground
        )))
    }

    @Test
    func freezesMutableFontDictionaryKeysValuesAndEntries() throws {
        let expectedFamilyKey = "family"
        let expectedSizeKey = "size"
        let expectedFamily = "mutable dictionary family"
        let expectedSize = 12
        let mutableFamilyKey = NSMutableString(string: expectedFamilyKey)
        let mutableSizeKey = NSMutableString(string: expectedSizeKey)
        let mutableFamily = NSMutableString(string: expectedFamily)
        let mutableFont = NSMutableDictionary()
        mutableFont.setObject(mutableFamily, forKey: mutableFamilyKey as NSString)
        mutableFont.setObject(NSNumber(value: expectedSize), forKey: mutableSizeKey as NSString)
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: styled("target", font: mutableFont),
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))

        mutableFamilyKey.setString("caller changed family key")
        mutableSizeKey.setString("caller changed size key")
        mutableFamily.setString("caller changed family")
        mutableFont.setObject(NSString(string: "caller added entry"), forKey: "extra" as NSString)

        let expectedFont = NSDictionary(dictionary: [
            expectedFamilyKey: expectedFamily,
            expectedSizeKey: NSNumber(value: expectedSize)
        ])
        #expect(proof.confirmsOriginal(styled("target", font: expectedFont)))
        #expect(proof.confirmsApplied(styled("replacement", font: expectedFont)))
        #expect(!proof.confirmsOriginal(styled("target", font: mutableFont)))
        #expect(!proof.confirmsApplied(styled("replacement", font: mutableFont)))
    }

    @Test
    func inverseUsesFrozenStyleAndRequiresTheExactOriginalResult() throws {
        let mutableFont = NSMutableDictionary(dictionary: [
            "family": "frozen inverse font",
            "size": NSNumber(value: 13)
        ])
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: styled("before target after", font: mutableFont),
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))
        mutableFont.setObject("caller changed inverse font", forKey: "family" as NSString)

        let inverse = try #require(proof.inverse(
            selectionRange: TextRange(location: 7, length: 11),
            selectedText: "replacement",
            replacement: "target"
        ))
        let expectedFont = NSDictionary(dictionary: [
            "family": "frozen inverse font",
            "size": NSNumber(value: 13)
        ])
        #expect(inverse.originalText.utf16.elementsEqual("before replacement after".utf16))
        #expect(inverse.expectedText.utf16.elementsEqual("before target after".utf16))
        #expect(inverse.confirmsOriginal(styled("before replacement after", font: expectedFont)))
        #expect(inverse.confirmsApplied(styled("before target after", font: expectedFont)))
        #expect(!inverse.confirmsApplied(styled("before target after", font: mutableFont)))
        #expect(proof.inverse(
            selectionRange: TextRange(location: 7, length: 11),
            selectedText: "replacement",
            replacement: "different"
        ) == nil)
        #expect(proof.inverse(
            selectionRange: TextRange(location: 0, length: 11),
            selectedText: "replacement",
            replacement: "target"
        ) == nil)
    }

    @Test
    func preservesExactUTF16StyleStringsAndFontKeys() throws {
        let decomposedFont = "precise font e\u{301}"
        let composedFont = "precise font é"
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: styled("target", font: decomposedFont),
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))
        #expect(proof.confirmsApplied(styled("text", font: decomposedFont)))
        #expect(!proof.confirmsApplied(styled("text", font: composedFont)))

        let dictionaryProof = try #require(ContenteditableTextStyleProof(
            originalValue: styled("target", font: NSDictionary(dictionary: [decomposedFont: "family"])),
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))
        #expect(dictionaryProof.confirmsApplied(styled("text", font: NSDictionary(dictionary: [decomposedFont: "family"]))))
        #expect(!dictionaryProof.confirmsApplied(styled("text", font: NSDictionary(dictionary: [composedFont: "family"]))))
    }

    @Test
    func enforcesFlatFontDictionarySizeLimits() throws {
        let maximumKey = String(repeating: "k", count: 128)
        let maximumString = String(repeating: "v", count: 1_024)
        var boundaryEntries: [String: Any] = [maximumKey: maximumString]
        for index in 1..<32 {
            boundaryEntries["font\(index)"] = NSNumber(value: index)
        }
        let boundaryFont = NSDictionary(dictionary: boundaryEntries)
        let accepted = try #require(ContenteditableTextStyleProof(
            originalValue: styled("target", font: boundaryFont),
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))

        #expect(accepted.confirmsApplied(styled("text", font: boundaryFont)))

        let tooManyEntries = NSMutableDictionary(dictionary: boundaryFont)
        tooManyEntries.setObject(NSNumber(value: 32), forKey: "extra" as NSString)
        let tooLongKey = NSDictionary(dictionary: [String(repeating: "k", count: 129): "value"])
        let tooLongValue = NSDictionary(dictionary: ["font": String(repeating: "v", count: 1_025)])
        let invalidFonts: [Any] = [NSDictionary(), tooManyEntries, tooLongKey, tooLongValue]

        for font in invalidFonts {
            #expect(ContenteditableTextStyleProof(
                originalValue: styled("target", font: font),
                selectionRange: TextRange(location: 0, length: 6),
                selectedText: "target",
                replacement: "text"
            ) == nil)
        }
    }

    @Test
    func rejectsNestedAndUnsupportedAttributeValues() {
        let nestedFont = NSDictionary(dictionary: [
            "font": NSDictionary(dictionary: ["family": "synthetic"])
        ])
        let unsupportedValues: [Any] = [
            nestedFont,
            NSArray(object: "synthetic"),
            NSData(data: Data([0x01])),
            NSNull(),
            NSObject()
        ]
        let nonStringKeyFont = NSMutableDictionary()
        nonStringKeyFont.setObject("synthetic", forKey: NSNumber(value: 1))

        for value in unsupportedValues {
            #expect(ContenteditableTextStyleProof(
                originalValue: styled("target", font: value),
                selectionRange: TextRange(location: 0, length: 6),
                selectedText: "target",
                replacement: "text"
            ) == nil)
            #expect(ContenteditableTextStyleProof(
                originalValue: styled("target", font: NSDictionary(dictionary: ["value": value])),
                selectionRange: TextRange(location: 0, length: 6),
                selectedText: "target",
                replacement: "text"
            ) == nil)
            #expect(ContenteditableTextStyleProof(
                originalValue: styled("target", foreground: value),
                selectionRange: TextRange(location: 0, length: 6),
                selectedText: "target",
                replacement: "text"
            ) == nil)
            #expect(ContenteditableTextStyleProof(
                originalValue: styled("target", background: value),
                selectionRange: TextRange(location: 0, length: 6),
                selectedText: "target",
                replacement: "text"
            ) == nil)
        }

        #expect(ContenteditableTextStyleProof(
            originalValue: styled("target", font: nonStringKeyFont),
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ) == nil)
    }

    @Test
    func rejectsStyleVariationInsideOrOutsideTheSelection() {
        let text = "left target right"
        let selection = TextRange(location: 5, length: 6)
        let selectedText = "target"
        let changedSelectionStyle = NSMutableAttributedString(attributedString: styled(text))
        changedSelectionStyle.addAttribute(
            fontAttribute,
            value: "different font",
            range: NSRange(location: 5, length: 1)
        )
        let changedContextStyle = NSMutableAttributedString(attributedString: styled(text))
        changedContextStyle.addAttribute(
            foregroundAttribute,
            value: "different foreground",
            range: NSRange(location: 12, length: 5)
        )

        #expect(ContenteditableTextStyleProof(
            originalValue: changedSelectionStyle,
            selectionRange: selection,
            selectedText: selectedText,
            replacement: "text"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: changedContextStyle,
            selectionRange: selection,
            selectedText: selectedText,
            replacement: "text"
        ) == nil)
    }

    @Test
    func copiesMutableInputBeforeItCanChange() throws {
        let mutableInput = NSMutableAttributedString(attributedString: styled("before target after"))
        let originalSnapshot = NSAttributedString(attributedString: mutableInput)
        let expected = styled("before replacement after")
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: mutableInput,
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))

        mutableInput.addAttribute(fontAttribute, value: "changed font", range: NSRange(location: 0, length: 1))
        mutableInput.replaceCharacters(in: NSRange(location: 0, length: mutableInput.length), with: "caller changed input")

        #expect(proof.originalValue.isEqual(to: originalSnapshot))
        #expect(proof.expectedValue.isEqual(to: expected))
        #expect(proof.confirmsOriginal(originalSnapshot))
        #expect(proof.confirmsApplied(expected))
    }

    @Test
    func confirmationsRejectLaterTextOrStyleChangesAnywhereInTheValue() throws {
        let original = styled("before target after")
        let applied = styled("before replacement after")
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))

        #expect(proof.confirmsApplied(applied))
        #expect(proof.confirmsOriginal(original))
        #expect(!proof.confirmsApplied(styled("Before replacement after")))
        #expect(!proof.confirmsApplied(styled("before replacement after!")))
        #expect(!proof.confirmsOriginal(styled("Before target after")))
        #expect(!proof.confirmsOriginal(styled("before target after!")))

        let appliedPrefixStyleEdit = NSMutableAttributedString(attributedString: applied)
        appliedPrefixStyleEdit.addAttribute(fontAttribute, value: "later font", range: NSRange(location: 0, length: 1))
        let appliedSuffixStyleEdit = NSMutableAttributedString(attributedString: applied)
        appliedSuffixStyleEdit.addAttribute(
            foregroundAttribute,
            value: "later foreground",
            range: NSRange(location: appliedSuffixStyleEdit.length - 1, length: 1)
        )
        let restoredPrefixStyleEdit = NSMutableAttributedString(attributedString: original)
        restoredPrefixStyleEdit.addAttribute(fontAttribute, value: "later font", range: NSRange(location: 0, length: 1))
        let restoredSuffixStyleEdit = NSMutableAttributedString(attributedString: original)
        restoredSuffixStyleEdit.addAttribute(
            foregroundAttribute,
            value: "later foreground",
            range: NSRange(location: restoredSuffixStyleEdit.length - 1, length: 1)
        )

        #expect(!proof.confirmsApplied(appliedPrefixStyleEdit))
        #expect(!proof.confirmsApplied(appliedSuffixStyleEdit))
        #expect(!proof.confirmsOriginal(restoredPrefixStyleEdit))
        #expect(!proof.confirmsOriginal(restoredSuffixStyleEdit))
    }

    private var fontAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXFont")
    }

    private var foregroundAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXForegroundColor")
    }

    private func styled(
        _ string: String,
        font: Any? = "synthetic font",
        foreground: Any? = "synthetic foreground",
        background: Any? = nil
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let font { attributes[fontAttribute] = font }
        if let foreground { attributes[foregroundAttribute] = foreground }
        if let background { attributes[NSAttributedString.Key(rawValue: "AXBackgroundColor")] = background }
        return NSAttributedString(string: string, attributes: attributes)
    }
}
