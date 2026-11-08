#if os(macOS)
import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct StructuredContenteditableStyleProofTests {
    @Test
    func provesObservedDisplayProjectionAndReversibleUniformSelectionReplacement() throws {
        let projection = try #require(paragraphProjection)
        let original = paragraphValue()
        let proof = try #require(paragraphProof())

        #expect(paragraphDisplayText.utf16.count == 81)
        #expect(paragraphCanonicalText.utf16.count == 79)
        #expect(projection.separatorOffsets == [34, 72])
        #expect(proof.originalText == paragraphDisplayText)
        #expect(proof.originalProjection.text == paragraphCanonicalText)
        #expect(proof.expectedProjection.separatorOffsets == [39, 77])
        #expect(proof.expectedProjection.text == paragraphCanonicalText.replacingOccurrences(of: "sample", with: "replacement"))
        #expect(proof.expectedText == paragraphDisplayTextWithReplacement("replacement"))
        #expect(proof.expectedText.utf16.count == 86)
        #expect(proof.confirmsOriginal(original))
        #expect(proof.confirmsApplied(paragraphValue(replacing: "replacement")))

        let clipboardProof = ContenteditableClipboardProof.structured(proof)
        #expect(clipboardProof.originalText == paragraphDisplayText)
        #expect(clipboardProof.expectedText == paragraphDisplayTextWithReplacement("replacement"))

        let inverse = try #require(clipboardProof.inverse(
            selectionRange: TextRange(location: sampleRange.location, length: "replacement".utf16.count),
            selectedText: "replacement",
            replacement: "sample"
        ))
        #expect(inverse.originalText == proof.expectedText)
        #expect(inverse.expectedText == proof.originalText)
        switch inverse {
        case .structured(let inverseProof):
            #expect(inverseProof.originalProjection == proof.expectedProjection)
            #expect(inverseProof.expectedProjection == proof.originalProjection)
            #expect(inverseProof.confirmsOriginal(paragraphValue(replacing: "replacement")))
            #expect(inverseProof.confirmsApplied(original))
        case .uniform:
            Issue.record("A structured proof must retain its case through inverse construction")
        }

        #expect(proof.inverse(
            selectionRange: TextRange(location: sampleRange.location, length: "replacement".utf16.count),
            selectedText: "different",
            replacement: "sample"
        ) == nil)
        #expect(proof.inverse(
            selectionRange: TextRange(location: sampleRange.location, length: "replacement".utf16.count),
            selectedText: "replacement",
            replacement: "different"
        ) == nil)
    }

    @Test
    func refusesSelectionsWithMixedStylesAndDisplayOnlySeparators() throws {
        let projection = try #require(paragraphProjection)
        let range = sampleRange
        let mixedSelection = styled(paragraphCanonicalText, runs: [
            (TextRange(location: 0, length: range.location), "prefix font", "prefix color"),
            (TextRange(location: range.location, length: 3), "sample font", "sample color"),
            (TextRange(location: range.location + 3, length: 3), "other sample font", "other sample color"),
            (TextRange(location: range.location + range.length, length: paragraphCanonicalText.utf16.count - range.location - range.length), "suffix font", "suffix color")
        ])
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: mixedSelection,
            projection: projection,
            selectionRange: range,
            selectedText: "sample",
            replacement: "replacement"
        ) == nil)

        let separatorRange = TextRange(location: projection.separatorOffsets[0] - 1, length: 2)
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: paragraphValue(),
            projection: projection,
            selectionRange: separatorRange,
            selectedText: " n",
            replacement: "word"
        ) == nil)

        for separator in ["\n", "\r", "\u{2028}", "\u{2029}", ""] {
            #expect(ContenteditableTextStyleProof.Structured(
                originalValue: paragraphValue(),
                projection: projection,
                selectionRange: range,
                selectedText: "sample",
                replacement: separator
            ) == nil)
        }
    }

    @Test
    func confirmationsRejectFullTextAndStyleDriftOutsideTheSelection() throws {
        let proof = try #require(paragraphProof())
        let expected = paragraphValue(replacing: "replacement")
        #expect(proof.confirmsApplied(expected))

        let changedText = NSMutableAttributedString(attributedString: expected)
        changedText.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
        #expect(!proof.confirmsApplied(changedText))

        let changedPrefixStyle = NSMutableAttributedString(attributedString: expected)
        changedPrefixStyle.addAttribute(fontAttribute, value: "later prefix font", range: NSRange(location: 0, length: 1))
        #expect(!proof.confirmsApplied(changedPrefixStyle))

        let changedSuffixStyle = NSMutableAttributedString(attributedString: expected)
        changedSuffixStyle.addAttribute(
            foregroundAttribute,
            value: "later suffix color",
            range: NSRange(location: expected.length - 1, length: 1)
        )
        #expect(!proof.confirmsApplied(changedSuffixStyle))

        let changedOriginalText = NSMutableAttributedString(attributedString: paragraphValue())
        changedOriginalText.replaceCharacters(in: NSRange(location: changedOriginalText.length - 1, length: 1), with: "!")
        #expect(!proof.confirmsOriginal(changedOriginalText))

        let changedOriginalStyle = NSMutableAttributedString(attributedString: paragraphValue())
        changedOriginalStyle.addAttribute(fontAttribute, value: "later original prefix font", range: NSRange(location: 0, length: 1))
        #expect(!proof.confirmsOriginal(changedOriginalStyle))
    }

    @Test
    func ignoresOnlyStrictBooleanSpellingAnnotationsAndRejectsUnknownAttributes() throws {
        let projection = try #require(paragraphProjection)
        let original = paragraphValue()
        let proof = try #require(paragraphProof())
        let annotationRange = NSRange(location: sampleRange.location, length: 1)

        for annotation in [NSNumber(value: true), NSNumber(value: false)] {
            #expect(proof.confirmsOriginal(annotated(original, value: annotation, range: annotationRange)))
        }

        let malformedAnnotations: [Any] = [NSString(string: "true"), NSNumber(value: 1), NSObject()]
        for annotation in malformedAnnotations {
            let malformed = annotated(original, value: annotation, range: annotationRange)
            #expect(ContenteditableTextStyleProof.Structured(
                originalValue: malformed,
                projection: projection,
                selectionRange: sampleRange,
                selectedText: "sample",
                replacement: "replacement"
            ) == nil)
            #expect(!proof.confirmsOriginal(malformed))
        }

        let unknown = NSMutableAttributedString(attributedString: original)
        unknown.addAttribute(
            NSAttributedString.Key(rawValue: "AXUnknown"),
            value: "unsupported",
            range: NSRange(location: 0, length: 1)
        )
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: unknown,
            projection: projection,
            selectionRange: sampleRange,
            selectedText: "sample",
            replacement: "replacement"
        ) == nil)
        #expect(!proof.confirmsOriginal(unknown))
    }

    @Test
    func requiresExactUtf16AndScalarAlignedSelection() throws {
        let text = "A😀B"
        let projection = try #require(ContenteditableTextProjection(displayText: text, leafTexts: [text]))
        let original = uniformlyStyled(text)

        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: original,
            projection: projection,
            selectionRange: TextRange(location: 1, length: 1),
            selectedText: "😀",
            replacement: "🚀"
        ) == nil)
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: original,
            projection: projection,
            selectionRange: TextRange(location: 1, length: 2),
            selectedText: "😀",
            replacement: "🚀"
        ) != nil)
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: original,
            projection: projection,
            selectionRange: TextRange(location: Int.max, length: 1),
            selectedText: "A",
            replacement: "x"
        ) == nil)

        let decomposed = "e\u{301}"
        let decomposedProjection = try #require(ContenteditableTextProjection(
            displayText: decomposed,
            leafTexts: [decomposed]
        ))
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: uniformlyStyled("é"),
            projection: decomposedProjection,
            selectionRange: TextRange(location: 0, length: 2),
            selectedText: decomposed,
            replacement: "x"
        ) == nil)
    }

    @Test
    func enforcesWholeValueLengthAndCanonicalRunLimits() throws {
        let maximumLength = ContenteditableTextStyleProof.maximumWholeValueUTF16Length
        let atLimit = String(repeating: "x", count: maximumLength)
        let projection = try #require(ContenteditableTextProjection(displayText: atLimit, leafTexts: [atLimit]))
        let valid = try #require(ContenteditableTextStyleProof.Structured(
            originalValue: uniformlyStyled(atLimit),
            projection: projection,
            selectionRange: TextRange(location: maximumLength - 1, length: 1),
            selectedText: "x",
            replacement: "y"
        ))
        #expect(valid.expectedText.utf16.count == maximumLength)
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: uniformlyStyled(atLimit),
            projection: projection,
            selectionRange: TextRange(location: maximumLength - 1, length: 1),
            selectedText: "x",
            replacement: "yy"
        ) == nil)

        let maximumRuns = 128
        let withinLimitText = String(repeating: "x", count: maximumRuns)
        let withinLimitProjection = try #require(ContenteditableTextProjection(
            displayText: withinLimitText,
            leafTexts: [withinLimitText]
        ))
        let withinLimit = try #require(ContenteditableTextStyleProof.Structured(
            originalValue: styled(withinLimitText, runs: styleRuns(count: maximumRuns)),
            projection: withinLimitProjection,
            selectionRange: TextRange(location: 0, length: 1),
            selectedText: "x",
            replacement: "y"
        ))
        #expect(withinLimit.confirmsOriginal(styled(withinLimitText, runs: styleRuns(count: maximumRuns))))

        let overLimitText = String(repeating: "x", count: maximumRuns + 1)
        let overLimitProjection = try #require(ContenteditableTextProjection(
            displayText: overLimitText,
            leafTexts: [overLimitText]
        ))
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: styled(overLimitText, runs: styleRuns(count: maximumRuns + 1)),
            projection: overLimitProjection,
            selectionRange: TextRange(location: 0, length: 1),
            selectedText: "x",
            replacement: "y"
        ) == nil)

        let annotationText = String(repeating: "x", count: maximumRuns + 1)
        let annotationProjection = try #require(ContenteditableTextProjection(
            displayText: annotationText,
            leafTexts: [annotationText]
        ))
        let annotationSplits = NSMutableAttributedString(attributedString: uniformlyStyled(annotationText))
        for offset in 0..<annotationText.utf16.count {
            annotationSplits.addAttribute(
                markedMisspelledAttribute,
                value: NSNumber(value: offset.isMultiple(of: 2)),
                range: NSRange(location: offset, length: 1)
            )
        }
        #expect(ContenteditableTextStyleProof.Structured(
            originalValue: annotationSplits,
            projection: annotationProjection,
            selectionRange: TextRange(location: 0, length: 1),
            selectedText: "x",
            replacement: "y"
        ) == nil)
    }

    @Test
    func freezesMutableCallerStylesForConfirmationAndInverse() throws {
        let originalText = "before sample after"
        let replacement = "replacement"
        let range = TextRange(location: 7, length: 6)
        let projection = try #require(ContenteditableTextProjection(
            displayText: originalText,
            leafTexts: [originalText]
        ))
        let mutableFamily = NSMutableString(string: "frozen family")
        let mutableFont = NSMutableDictionary(dictionary: [
            "family": mutableFamily,
            "size": NSNumber(value: 13)
        ])
        let mutableForeground = NSMutableString(string: "frozen foreground")
        let original = NSAttributedString(string: originalText, attributes: [
            fontAttribute: mutableFont,
            foregroundAttribute: mutableForeground
        ])
        let proof = try #require(ContenteditableTextStyleProof.Structured(
            originalValue: original,
            projection: projection,
            selectionRange: range,
            selectedText: "sample",
            replacement: replacement
        ))

        mutableFamily.setString("caller changed family")
        mutableFont.setObject("caller added entry", forKey: "extra" as NSString)
        mutableForeground.setString("caller changed foreground")

        let frozenFont = NSDictionary(dictionary: [
            "family": "frozen family",
            "size": NSNumber(value: 13)
        ])
        let frozenOriginal = uniformlyStyled(originalText, font: frozenFont, foreground: "frozen foreground")
        let frozenExpected = uniformlyStyled("before replacement after", font: frozenFont, foreground: "frozen foreground")
        #expect(proof.confirmsOriginal(frozenOriginal))
        #expect(proof.confirmsApplied(frozenExpected))
        #expect(!proof.confirmsOriginal(original))

        let inverse = try #require(proof.inverse(
            selectionRange: TextRange(location: range.location, length: replacement.utf16.count),
            selectedText: replacement,
            replacement: "sample"
        ))
        #expect(inverse.confirmsOriginal(frozenExpected))
        #expect(inverse.confirmsApplied(frozenOriginal))
    }

    @Test
    func clipboardWrapperPreservesUniformProofCaseAndInverse() throws {
        let text = "before sample after"
        let projection = try #require(ContenteditableTextProjection(displayText: text, leafTexts: [text]))
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: uniformlyStyled(text),
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "sample",
            replacement: "replacement"
        ))
        let clipboardProof = ContenteditableClipboardProof.uniform(proof)

        #expect(clipboardProof.originalText == text)
        #expect(clipboardProof.expectedText == "before replacement after")
        let inverse = try #require(clipboardProof.inverse(
            selectionRange: TextRange(location: 7, length: "replacement".utf16.count),
            selectedText: "replacement",
            replacement: "sample"
        ))
        #expect(inverse.originalText == "before replacement after")
        #expect(inverse.expectedText == text)
        if case .uniform(let inverseProof) = inverse {
            #expect(inverseProof.confirmsApplied(uniformlyStyled(text)))
        } else {
            Issue.record("A uniform proof must retain its case through inverse construction")
        }

        #expect(projection.text == text)
    }

    private var paragraphLeaves: [String] {
        [
            "A short ",
            "sample",
            " paragraph includes ",
            "nested styles ",
            "across multiple AX text ",
            "leaves."
        ]
    }

    private var paragraphCanonicalText: String { paragraphLeaves.joined() }

    private var paragraphDisplayText: String {
        paragraphLeaves.enumerated().map { index, leaf in
            index == 3 || index == 5 ? "\n" + leaf : leaf
        }.joined()
    }

    private var paragraphProjection: ContenteditableTextProjection? {
        ContenteditableTextProjection(displayText: paragraphDisplayText, leafTexts: paragraphLeaves)
    }

    private var sampleRange: TextRange {
        TextRange(location: paragraphLeaves[0].utf16.count, length: paragraphLeaves[1].utf16.count)
    }

    private func paragraphValue(replacing replacement: String = "sample") -> NSAttributedString {
        let expectedText = paragraphLeaves.enumerated().map { index, leaf in
            index == 1 ? replacement : leaf
        }.joined()
        let suffixLocation = sampleRange.location + replacement.utf16.count
        return styled(expectedText, runs: [
            (TextRange(location: 0, length: sampleRange.location), "prefix font", "prefix color"),
            (TextRange(location: sampleRange.location, length: replacement.utf16.count), "sample font", "sample color"),
            (TextRange(location: suffixLocation, length: expectedText.utf16.count - suffixLocation), "suffix font", "suffix color")
        ])
    }

    private func paragraphProof(replacement: String = "replacement") -> ContenteditableTextStyleProof.Structured? {
        guard let projection = paragraphProjection else { return nil }
        return ContenteditableTextStyleProof.Structured(
            originalValue: paragraphValue(),
            projection: projection,
            selectionRange: sampleRange,
            selectedText: "sample",
            replacement: replacement
        )
    }

    private func paragraphDisplayTextWithReplacement(_ replacement: String) -> String {
        paragraphLeaves.enumerated().map { index, leaf in
            let value = index == 1 ? replacement : leaf
            return index == 3 || index == 5 ? "\n" + value : value
        }.joined()
    }

    private var fontAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXFont")
    }

    private var foregroundAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXForegroundColor")
    }

    private var markedMisspelledAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXMarkedMisspelled")
    }

    private func uniformlyStyled(
        _ text: String,
        font: Any = "synthetic font",
        foreground: Any = "synthetic foreground"
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            fontAttribute: font,
            foregroundAttribute: foreground
        ])
    }

    private func styled(
        _ text: String,
        runs: [(range: TextRange, font: Any, foreground: Any)]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        for run in runs {
            result.setAttributes([
                fontAttribute: run.font,
                foregroundAttribute: run.foreground
            ], range: NSRange(location: run.range.location, length: run.range.length))
        }
        return NSAttributedString(attributedString: result)
    }

    private func styleRuns(count: Int) -> [(range: TextRange, font: Any, foreground: Any)] {
        (0..<count).map { index in
            (
                range: TextRange(location: index, length: 1),
                font: "font-\(index)" as Any,
                foreground: "foreground-\(index)" as Any
            )
        }
    }

    private func annotated(
        _ value: NSAttributedString,
        value annotation: Any,
        range: NSRange
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: value)
        result.addAttribute(markedMisspelledAttribute, value: annotation, range: range)
        return result
    }
}
#endif
