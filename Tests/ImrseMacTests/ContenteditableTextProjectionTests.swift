import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct ContenteditableTextProjectionTests {
    private static let displayText = "Rich bold sample amber\nOuter nested rich sample birch text\nMultiline sample cedar"
    private static let leafTexts = [
        "Rich bold sample amber",
        "Outer ",
        "nested ",
        "rich sample birch",
        " text",
        "Multiline sample cedar"
    ]

    private func fixture() throws -> ContenteditableTextProjection {
        try #require(ContenteditableTextProjection(displayText: Self.displayText, leafTexts: Self.leafTexts))
    }

    @Test
    func separatesDisplayTextFromCanonicalLeafConcatenation() throws {
        let projection = try fixture()

        #expect(projection.displayText == Self.displayText)
        #expect(projection.text == "Rich bold sample amberOuter nested rich sample birch textMultiline sample cedar")
        #expect(projection.displayText.utf16.count == 81)
        #expect(projection.text.utf16.count == 79)
        #expect(projection.separatorOffsets == [22, 57])
    }

    @Test(arguments: [
        (TextRange(location: 10, length: 6), 10, "sample"),
        (TextRange(location: 40, length: 6), 41, "sample"),
        (TextRange(location: 67, length: 6), 69, "sample"),
        (TextRange(location: 17, length: 5), 17, "amber"),
        (TextRange(location: 22, length: 5), 23, "Outer")
    ])
    func mapsScalarSafeRangesAcrossDisplaySeparators(
        _ range: ImrseCore.TextRange,
        toDisplayLocation expectedLocation: Int,
        selecting expectedText: String
    ) throws {
        let projection = try fixture()
        let displayRange = try #require(projection.displayRange(for: range))

        #expect(displayRange == TextRange(location: expectedLocation, length: range.length))
        #expect(UTF16SelectionRange.substring(projection.text, range: range) == expectedText)
        #expect(UTF16SelectionRange.substring(projection.displayText, range: displayRange) == expectedText)
    }

    @Test
    func replacementShiftsDisplayOnlySeparatorsAndCanBeInverted() throws {
        let original = try fixture()
        let replaced = try #require(original.replacing(
            range: TextRange(location: 10, length: 6),
            with: "replacement"
        ))

        #expect(replaced.text == "Rich bold replacement amberOuter nested rich sample birch textMultiline sample cedar")
        #expect(replaced.displayText == "Rich bold replacement amber\nOuter nested rich sample birch text\nMultiline sample cedar")
        #expect(replaced.separatorOffsets == [27, 62])

        let restored = try #require(replaced.replacing(
            range: TextRange(location: 10, length: 11),
            with: "sample"
        ))
        #expect(restored == original)
    }

    @Test
    func replacementInLaterParagraphUsesDisplayCoordinatesPastNewlines() throws {
        let projection = try fixture()
        let replaced = try #require(projection.replacing(
            range: TextRange(location: 67, length: 6),
            with: "replacement"
        ))

        #expect(replaced.text == "Rich bold sample amberOuter nested rich sample birch textMultiline replacement cedar")
        #expect(replaced.displayText == "Rich bold sample amber\nOuter nested rich sample birch text\nMultiline replacement cedar")
        #expect(replaced.separatorOffsets == [22, 57])

        let mappedRange = try #require(replaced.displayRange(for: TextRange(location: 67, length: 11)))
        #expect(mappedRange == TextRange(location: 69, length: 11))
        #expect(UTF16SelectionRange.substring(replaced.displayText, range: mappedRange) == "replacement")
    }

    @Test(arguments: [
        TextRange(location: -1, length: 1),
        TextRange(location: 0, length: -1),
        TextRange(location: 0, length: 0),
        TextRange(location: 20, length: 4),
        TextRange(location: 79, length: 1),
        TextRange(location: Int.max, length: 1)
    ])
    func rejectsInvalidEmptyOverflowingAndParagraphCrossingRanges(_ range: ImrseCore.TextRange) throws {
        let projection = try fixture()

        #expect(projection.displayRange(for: range) == nil)
        #expect(projection.replacing(range: range, with: "x") == nil)
    }

    @Test
    func rejectsRangesThatSplitSurrogatePairs() throws {
        let projection = try #require(ContenteditableTextProjection(displayText: "A😀B", leafTexts: ["A😀B"]))

        #expect(projection.displayRange(for: TextRange(location: 1, length: 1)) == nil)
        #expect(projection.displayRange(for: TextRange(location: 2, length: 1)) == nil)
        #expect(projection.displayRange(for: TextRange(location: 1, length: 2)) == TextRange(location: 1, length: 2))
    }

    @Test(arguments: [
        ("", ["first"]),
        ("first", []),
        ("first", [""]),
        ("\nfirst", ["first"]),
        ("first\n", ["first"]),
        ("first\n\nsecond", ["first", "second"]),
        ("Outer nested rich sample birch text", ["Outer", "nested", "rich sample birch", "text"]),
        ("same extra same", ["same", "same"]),
        ("second first", ["first", "second"]),
        ("firstX", ["first"])
    ])
    func rejectsMalformedDisplayAndLeafSequences(_ displayText: String, _ leafTexts: [String]) {
        #expect(ContenteditableTextProjection(displayText: displayText, leafTexts: leafTexts) == nil)
    }

    @Test(arguments: ["\n", "\r", "\u{2028}", "\u{2029}"])
    func rejectsLineSeparatorsInsideLeaves(_ separator: String) {
        let leaf = "before\(separator)after"

        #expect(ContenteditableTextProjection(displayText: leaf, leafTexts: [leaf]) == nil)
    }

    @Test
    func requiresExactUTF16LeafMatchesWithoutUnicodeNormalization() {
        let precomposed = "é"
        let decomposed = "e\u{301}"

        #expect(precomposed == decomposed)
        #expect(!precomposed.utf16.elementsEqual(decomposed.utf16))
        #expect(ContenteditableTextProjection(displayText: precomposed, leafTexts: [decomposed]) == nil)
    }

    @Test
    func enforcesWholeTextAndLeafCountLimits() throws {
        let maximumLength = 65_536
        let maximumText = String(repeating: "x", count: maximumLength)
        let maximumProjection = try #require(ContenteditableTextProjection(
            displayText: maximumText,
            leafTexts: [maximumText]
        ))
        #expect(maximumProjection.displayText.utf16.count == maximumLength)
        #expect(maximumProjection.text.utf16.count == maximumLength)

        let left = String(repeating: "x", count: 32_768)
        let right = String(repeating: "y", count: 32_767)
        let maximumDisplay = try #require(ContenteditableTextProjection(
            displayText: "\(left)\n\(right)",
            leafTexts: [left, right]
        ))
        #expect(maximumDisplay.displayText.utf16.count == maximumLength)
        #expect(maximumDisplay.text.utf16.count == maximumLength - 1)

        #expect(ContenteditableTextProjection(
            displayText: String(repeating: "x", count: maximumLength + 1),
            leafTexts: [String(repeating: "x", count: maximumLength + 1)]
        ) == nil)
        #expect(ContenteditableTextProjection(
            displayText: String(repeating: "x", count: 65),
            leafTexts: Array(repeating: "x", count: 65)
        ) == nil)
        #expect(ContenteditableTextProjection(
            displayText: String(repeating: "x", count: 64),
            leafTexts: Array(repeating: "x", count: 64)
        ) != nil)
    }

    @Test
    func rejectsEmptyReplacement() throws {
        let projection = try fixture()

        #expect(projection.replacing(range: TextRange(location: 10, length: 6), with: "") == nil)
    }

    @Test(arguments: ["\n", "\r", "\u{2028}", "\u{2029}"])
    func rejectsLineSeparatorsInReplacement(_ separator: String) throws {
        let projection = try fixture()

        #expect(projection.replacing(
            range: TextRange(location: 10, length: 6),
            with: "before\(separator)after"
        ) == nil)
    }
}
