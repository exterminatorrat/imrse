import AppKit
import CoreFoundation
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
        let boolean: CFBoolean = kCFBooleanTrue
        let unknownBooleanAttribute = NSMutableAttributedString(attributedString: styled("target"))
        unknownBooleanAttribute.addAttribute(
            NSAttributedString.Key(rawValue: "AXUnknownBoolean"),
            value: boolean,
            range: NSRange(location: 0, length: 6)
        )
        #expect(ContenteditableTextStyleProof(
            originalValue: unknownAttributeValue,
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "target",
            replacement: "text"
        ) == nil)
        #expect(ContenteditableTextStyleProof(
            originalValue: unknownBooleanAttribute,
            selectionRange: TextRange(location: 0, length: 6),
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

    @Test(arguments: [false, true])
    func reconstructsFontDictionaryBooleansAsCFBooleans(_ enabled: Bool) throws {
        let font = fontDictionaryWithBoolean(enabled)
        let original = styledWithFontDictionary("target", font: font)
        let inputBoolean = try fontDictionaryLeaf(in: original)
        #expect(CFGetTypeID(inputBoolean as CFTypeRef) == CFBooleanGetTypeID())
        #expect(inputBoolean.boolValue == enabled)
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))

        for value in [proof.originalValue, proof.expectedValue] {
            let frozenFont = try #require(value.attribute(fontAttribute, at: 0, effectiveRange: nil) as? NSDictionary)
            let frozenBoolean = try #require(frozenFont["enabled"] as? NSNumber)
            #expect(CFGetTypeID(frozenBoolean) == CFBooleanGetTypeID())
            #expect(frozenBoolean.boolValue == enabled)
        }

        let applied = styledWithFontDictionary("text", font: font)
        let appliedBoolean = try fontDictionaryLeaf(in: applied)
        #expect(CFGetTypeID(appliedBoolean as CFTypeRef) == CFBooleanGetTypeID())
        #expect(appliedBoolean.boolValue == enabled)
        #expect(proof.confirmsOriginal(original))
        #expect(proof.confirmsApplied(applied))
    }

    @Test(arguments: [false, true])
    func distinguishesFontDictionaryBooleansFromNumbers(_ enabled: Bool) throws {
        let booleanFont = fontDictionaryWithBoolean(enabled)
        let numericFont = NSDictionary(dictionary: ["enabled": NSNumber(value: enabled ? 1 : 0)])
        let booleanInput = styledWithFontDictionary("target", font: booleanFont)
        let numericInput = styledWithFontDictionary("target", font: numericFont)
        let booleanInputValue = try fontDictionaryLeaf(in: booleanInput)
        let numericInputValue = try fontDictionaryLeaf(in: numericInput)
        #expect(CFGetTypeID(booleanInputValue as CFTypeRef) == CFBooleanGetTypeID())
        #expect(booleanInputValue.boolValue == enabled)
        #expect(CFGetTypeID(numericInputValue as CFTypeRef) == CFNumberGetTypeID())
        #expect(CFGetTypeID(numericInputValue as CFTypeRef) != CFBooleanGetTypeID())
        #expect(numericInputValue.intValue == (enabled ? 1 : 0))
        let booleanProof = try #require(ContenteditableTextStyleProof(
            originalValue: booleanInput,
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))
        let numericProof = try #require(ContenteditableTextStyleProof(
            originalValue: numericInput,
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))

        let booleanActual = styledWithFontDictionary("text", font: booleanFont)
        let numericActual = styledWithFontDictionary("text", font: numericFont)
        let booleanActualValue = try fontDictionaryLeaf(in: booleanActual)
        let numericActualValue = try fontDictionaryLeaf(in: numericActual)
        #expect(CFGetTypeID(booleanActualValue as CFTypeRef) == CFBooleanGetTypeID())
        #expect(booleanActualValue.boolValue == enabled)
        #expect(CFGetTypeID(numericActualValue as CFTypeRef) == CFNumberGetTypeID())
        #expect(CFGetTypeID(numericActualValue as CFTypeRef) != CFBooleanGetTypeID())
        #expect(numericActualValue.intValue == (enabled ? 1 : 0))
        #expect(booleanProof.confirmsApplied(booleanActual))
        #expect(!booleanProof.confirmsApplied(numericActual))
        #expect(numericProof.confirmsApplied(numericActual))
        #expect(!numericProof.confirmsApplied(booleanActual))
    }

    @Test
    func freezesMutableBooleanFontDictionaryKeysAndValues() throws {
        let trueValue: CFBoolean = kCFBooleanTrue
        let falseValue: CFBoolean = kCFBooleanFalse
        let mutableKey = NSMutableString(string: "enabled")
        let mutableFont = NSMutableDictionary()
        mutableFont.setObject(trueValue, forKey: mutableKey as NSString)
        let original = styledWithFontDictionary("target", font: mutableFont)
        let inputBoolean = try fontDictionaryLeaf(in: original)
        #expect(CFGetTypeID(inputBoolean as CFTypeRef) == CFBooleanGetTypeID())
        #expect(inputBoolean.boolValue)
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 0, length: 6),
            selectedText: "target",
            replacement: "text"
        ))

        mutableKey.setString("changed key")
        mutableFont.removeObject(forKey: "enabled" as NSString)
        mutableFont.setObject(falseValue, forKey: "changed key" as NSString)
        mutableFont.setObject(trueValue, forKey: "added key" as NSString)

        let frozenFont = fontDictionaryWithBoolean(true)
        #expect(proof.originalValue.isEqual(to: styledWithFontDictionary("target", font: frozenFont)))
        #expect(proof.expectedValue.isEqual(to: styledWithFontDictionary("text", font: frozenFont)))
        #expect(proof.confirmsOriginal(styledWithFontDictionary("target", font: frozenFont)))
        #expect(!proof.confirmsOriginal(styledWithFontDictionary("target", font: mutableFont)))
        #expect(!proof.confirmsApplied(styledWithFontDictionary("text", font: mutableFont)))
    }

    @Test
    func expectedAndInverseProofsRefuseFlippedFontDictionaryBooleans() throws {
        let font = fontDictionaryWithBoolean(true)
        let flippedFont = fontDictionaryWithBoolean(false)
        let original = styledWithFontDictionary("before target after", font: font)
        let originalBoolean = try fontDictionaryLeaf(in: original)
        let flippedOriginal = styledWithFontDictionary("before target after", font: flippedFont)
        let flippedOriginalBoolean = try fontDictionaryLeaf(in: flippedOriginal)
        #expect(CFGetTypeID(originalBoolean as CFTypeRef) == CFBooleanGetTypeID())
        #expect(originalBoolean.boolValue)
        #expect(CFGetTypeID(flippedOriginalBoolean as CFTypeRef) == CFBooleanGetTypeID())
        #expect(!flippedOriginalBoolean.boolValue)
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))
        let inverse = try #require(proof.inverse(
            selectionRange: TextRange(location: 7, length: 11),
            selectedText: "replacement",
            replacement: "target"
        ))

        let applied = styledWithFontDictionary("before replacement after", font: font)
        let restored = styledWithFontDictionary("before target after", font: font)
        let flippedApplied = styledWithFontDictionary("before replacement after", font: flippedFont)
        let flippedRestored = styledWithFontDictionary("before target after", font: flippedFont)
        for value in [applied, restored] {
            let boolean = try fontDictionaryLeaf(in: value)
            #expect(CFGetTypeID(boolean as CFTypeRef) == CFBooleanGetTypeID())
            #expect(boolean.boolValue)
        }
        for value in [flippedApplied, flippedRestored] {
            let boolean = try fontDictionaryLeaf(in: value)
            #expect(CFGetTypeID(boolean as CFTypeRef) == CFBooleanGetTypeID())
            #expect(!boolean.boolValue)
        }
        #expect(proof.confirmsApplied(applied))
        #expect(!proof.confirmsApplied(flippedApplied))
        #expect(!proof.confirmsOriginal(flippedRestored))
        #expect(inverse.confirmsOriginal(applied))
        #expect(inverse.confirmsApplied(restored))
        #expect(!inverse.confirmsOriginal(flippedApplied))
        #expect(!inverse.confirmsApplied(flippedRestored))
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
        let boolean: CFBoolean = kCFBooleanTrue
        let tooManyBooleanEntries = NSMutableDictionary()
        for index in 0..<33 {
            tooManyBooleanEntries.setObject(boolean, forKey: "trait\(index)" as NSString)
        }
        let tooLongKey = NSDictionary(dictionary: [String(repeating: "k", count: 129): "value"])
        let tooLongValue = NSDictionary(dictionary: ["font": String(repeating: "v", count: 1_025)])
        let invalidFonts: [Any] = [NSDictionary(), tooManyEntries, tooManyBooleanEntries, tooLongKey, tooLongValue]

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
        let boolean: CFBoolean = kCFBooleanTrue
        let nestedFont = NSDictionary(dictionary: [
            "font": NSDictionary(dictionary: ["family": "synthetic"])
        ])
        let nestedBooleanFont = NSDictionary(dictionary: [
            "trait": NSDictionary(dictionary: ["enabled": boolean])
        ])
        let unsupportedValues: [Any] = [
            nestedFont,
            nestedBooleanFont,
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

    private func fontDictionaryWithBoolean(_ enabled: Bool) -> NSDictionary {
        let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        return NSDictionary(dictionary: ["enabled": value])
    }

    private func fontDictionaryLeaf(in value: NSAttributedString) throws -> NSNumber {
        let font = try #require(value.attribute(fontAttribute, at: 0, effectiveRange: nil) as? NSDictionary)
        return try #require(font["enabled"] as? NSNumber)
    }

    private func styledWithFontDictionary(_ string: String, font: NSDictionary) -> NSAttributedString {
        TypePreservingFontDictionaryString(base: styled(string, font: nil), font: font)
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

private final class TypePreservingFontDictionaryString: NSAttributedString {
    private let base: NSAttributedString
    private let font: NSDictionary
    private let fontKey = NSAttributedString.Key("AXFont")

    init(base: NSAttributedString, font: NSDictionary) {
        self.base = base
        self.font = font
        super.init()
    }

    required init?(coder: NSCoder) { return nil }

    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { return nil }

    override var string: String { base.string }
    override var length: Int { base.length }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        precondition(location >= 0 && location < base.length)
        var baseRange = NSRange()
        var result = base.attributes(at: location, effectiveRange: &baseRange)
        result[fontKey] = font
        range?.pointee = baseRange
        return result
    }
}
