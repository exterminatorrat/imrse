import CoreFoundation
import CoreGraphics
import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct ContenteditableSpellingAnnotationTests {
    @Test
    func confirmsObservedPartialReplacementWhenSpellingAddsThreeAttributeRuns() throws {
        let originalText = "plaintext-only sample juniper"
        let appliedText = "plaintext-only Synthétique juniper"
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: styled(originalText),
            selectionRange: TextRange(location: 15, length: 6),
            selectedText: "sample",
            replacement: "Synthétique"
        ))
        let applied = annotated(
            styled(appliedText),
            value: NSNumber(value: true),
            range: NSRange(location: 15, length: 11)
        )

        #expect(originalText.utf16.count == 29)
        #expect(appliedText.utf16.count == 34)
        let annotation = try #require(applied.attribute(markedMisspelledAttribute, at: 15, effectiveRange: nil))
        #expect(CFGetTypeID(annotation as CFTypeRef) == CFBooleanGetTypeID())
        #expect(proof.confirmsApplied(applied))
        let inverse = try #require(proof.inverse(
            selectionRange: TextRange(location: 15, length: 11),
            selectedText: "Synthétique",
            replacement: "sample"
        ))
        #expect(inverse.confirmsOriginal(applied))
        #expect(inverse.expectedText.utf16.elementsEqual(originalText.utf16))
        #expect(inverse.confirmsApplied(styled(originalText)))
        #expect(!proof.confirmsApplied(annotated(
            styled(appliedText + "X"),
            value: NSNumber(value: true),
            range: NSRange(location: 15, length: 11)
        )))
    }

    @Test
    func provesAccentedLengthChangingReplacementAndInverseAcrossSpellingRuns() throws {
        let originalText = "juniper"
        let replacement = "Synthétique juniper"
        let background = "synthetic background"
        let trueAnnotation = NSNumber(value: true)
        let falseAnnotation = NSNumber(value: false)
        let original = annotated(
            styled(originalText, background: background),
            value: trueAnnotation,
            range: NSRange(location: 0, length: originalText.utf16.count)
        )
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: originalText.utf16.count),
            selectedText: originalText,
            replacement: replacement
        ))

        #expect(CFGetTypeID(trueAnnotation as CFTypeRef) == CFBooleanGetTypeID())
        #expect(CFGetTypeID(falseAnnotation as CFTypeRef) == CFBooleanGetTypeID())
        #expect(originalText.utf16.count == 7)
        #expect(replacement.utf16.count == 19)
        #expect(proof.originalText.utf16.elementsEqual(originalText.utf16))
        #expect(proof.expectedText.utf16.elementsEqual(replacement.utf16))
        #expect(proof.confirmsOriginal(original))
        #expect(proof.originalValue.isEqual(to: styled(originalText, background: background)))
        #expect(proof.expectedValue.isEqual(to: styled(replacement, background: background)))
        #expect(proof.expectedValue.attribute(markedMisspelledAttribute, at: 0, effectiveRange: nil) == nil)

        let markedReplacementPrefix = annotated(
            proof.expectedValue,
            value: trueAnnotation,
            range: NSRange(location: 0, length: "Synthétique".utf16.count)
        )
        let markedOriginalWord = annotated(
            proof.expectedValue,
            value: falseAnnotation,
            range: NSRange(location: "Synthétique ".utf16.count, length: originalText.utf16.count)
        )
        #expect(proof.confirmsApplied(markedReplacementPrefix))
        #expect(proof.confirmsApplied(markedOriginalWord))
        #expect(proof.confirmsApplied(proof.expectedValue))

        let inverse = try #require(proof.inverse(
            selectionRange: TextRange(location: 0, length: replacement.utf16.count),
            selectedText: replacement,
            replacement: originalText
        ))
        #expect(inverse.originalText.utf16.elementsEqual(replacement.utf16))
        #expect(inverse.expectedText.utf16.elementsEqual(originalText.utf16))
        #expect(inverse.confirmsOriginal(markedReplacementPrefix))
        #expect(inverse.confirmsOriginal(markedOriginalWord))
        #expect(inverse.expectedValue.isEqual(to: styled(originalText, background: background)))
        #expect(inverse.expectedValue.attribute(markedMisspelledAttribute, at: 0, effectiveRange: nil) == nil)
        #expect(inverse.confirmsApplied(original))
        #expect(inverse.confirmsApplied(proof.originalValue))
    }

    @Test
    func refusesNonBooleanSpellingAnnotationsAndUnknownAttributes() throws {
        let originalText = "juniper"
        let replacement = "Synthétique juniper"
        let original = styled(originalText)
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: originalText.utf16.count),
            selectedText: originalText,
            replacement: replacement
        ))
        let invalidAnnotations: [Any] = [
            NSString(string: "true"),
            NSNumber(value: 1),
            NSObject()
        ]

        for value in invalidAnnotations {
            #expect(ContenteditableTextStyleProof(
                originalValue: annotated(
                    original,
                    value: value,
                    range: NSRange(location: 0, length: originalText.utf16.count)
                ),
                selectionRange: TextRange(location: 0, length: originalText.utf16.count),
                selectedText: originalText,
                replacement: replacement
            ) == nil)
            #expect(!proof.confirmsApplied(annotated(
                proof.expectedValue,
                value: value,
                range: NSRange(location: 0, length: 1)
            )))
        }

        let unknownAttribute = NSAttributedString.Key(rawValue: "AXUnknown")
        let unknownOriginal = NSMutableAttributedString(attributedString: original)
        unknownOriginal.addAttribute(
            unknownAttribute,
            value: "unsupported",
            range: NSRange(location: 0, length: 1)
        )
        #expect(ContenteditableTextStyleProof(
            originalValue: unknownOriginal,
            selectionRange: TextRange(location: 0, length: originalText.utf16.count),
            selectedText: originalText,
            replacement: replacement
        ) == nil)

        let unknownApplied = NSMutableAttributedString(attributedString: annotated(
            proof.expectedValue,
            value: NSNumber(value: true),
            range: NSRange(location: 0, length: 1)
        ))
        unknownApplied.addAttribute(
            unknownAttribute,
            value: "unsupported",
            range: NSRange(location: 0, length: 1)
        )
        #expect(!proof.confirmsApplied(unknownApplied))
    }

    @Test
    func rejectsTextAndVisualStyleChangesInAnnotatedAndUnannotatedRuns() throws {
        let originalText = "juniper"
        let replacement = "Synthétique juniper"
        let background = "synthetic background"
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: styled(originalText, background: background),
            selectionRange: TextRange(location: 0, length: originalText.utf16.count),
            selectedText: originalText,
            replacement: replacement
        ))
        let annotatedValue = annotated(
            proof.expectedValue,
            value: NSNumber(value: true),
            range: NSRange(location: 0, length: "Synthétique".utf16.count)
        )
        let unannotatedRunLocation = "Synthétique ".utf16.count

        for (location, changedCharacter) in [(0, "s"), (unannotatedRunLocation, "J")] {
            let changedText = NSMutableAttributedString(attributedString: annotatedValue)
            changedText.replaceCharacters(in: NSRange(location: location, length: 1), with: changedCharacter)
            #expect(!proof.confirmsApplied(changedText))
        }

        let styleChanges: [(NSAttributedString.Key, NSRange, Any)] = [
            (fontAttribute, NSRange(location: 0, length: 1), "changed marked font"),
            (fontAttribute, NSRange(location: unannotatedRunLocation, length: 1), "changed plain font"),
            (foregroundAttribute, NSRange(location: 0, length: 1), "changed marked foreground"),
            (foregroundAttribute, NSRange(location: unannotatedRunLocation, length: 1), "changed plain foreground"),
            (backgroundAttribute, NSRange(location: 0, length: 1), "changed marked background"),
            (backgroundAttribute, NSRange(location: unannotatedRunLocation, length: 1), "changed plain background")
        ]
        for (attribute, range, value) in styleChanges {
            let changedStyle = NSMutableAttributedString(attributedString: annotatedValue)
            changedStyle.addAttribute(attribute, value: value, range: range)
            #expect(!proof.confirmsApplied(changedStyle))
        }
    }

    private var fontAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXFont")
    }

    private var foregroundAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXForegroundColor")
    }

    private var backgroundAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXBackgroundColor")
    }

    private var markedMisspelledAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXMarkedMisspelled")
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
        if let background { attributes[backgroundAttribute] = background }
        return NSAttributedString(string: string, attributes: attributes)
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
