#if os(macOS)
import Foundation
import ImrseCore

struct ContenteditableTextProjection: Equatable {
    private static let maximumLength = 65_536
    private let displayUTF16: [UInt16]
    private let textUTF16: [UInt16]
    let separatorOffsets: [Int]

    var displayText: String { String(decoding: displayUTF16, as: UTF16.self) }
    var text: String { String(decoding: textUTF16, as: UTF16.self) }

    init?(displayText: String, leafTexts: [String]) {
        let display = Array(displayText.utf16)
        guard !display.isEmpty,
              display.count <= Self.maximumLength,
              !leafTexts.isEmpty,
              leafTexts.count <= 64
        else { return nil }

        var canonical: [UInt16] = []
        var separators: [Int] = []
        var offset = 0
        for (index, leaf) in leafTexts.enumerated() {
            let units = Array(leaf.utf16)
            guard !units.isEmpty,
                  units.count <= Self.maximumLength - canonical.count,
                  !units.contains(where: Self.isLineSeparator)
            else { return nil }
            if index > 0, offset < display.count, display[offset] == 0x000A {
                separators.append(canonical.count)
                offset += 1
            }
            guard offset <= display.count,
                  units.count <= display.count - offset,
                  display[offset..<(offset + units.count)].elementsEqual(units)
            else { return nil }
            canonical.append(contentsOf: units)
            offset += units.count
        }
        guard offset == display.count else { return nil }
        displayUTF16 = display
        textUTF16 = canonical
        separatorOffsets = separators
    }

    private init(displayUTF16: [UInt16], textUTF16: [UInt16], separatorOffsets: [Int]) {
        self.displayUTF16 = displayUTF16
        self.textUTF16 = textUTF16
        self.separatorOffsets = separatorOffsets
    }

    func displayRange(for range: ImrseCore.TextRange) -> ImrseCore.TextRange? {
        guard range.length > 0,
              UTF16SelectionRange.substring(text, range: range) != nil
        else { return nil }
        let end = range.location + range.length
        guard !separatorOffsets.contains(where: { range.location < $0 && $0 < end }) else { return nil }
        let preceding = separatorOffsets.filter { $0 <= range.location }.count
        return ImrseCore.TextRange(location: range.location + preceding, length: range.length)
    }

    func replacing(range: ImrseCore.TextRange, with replacement: String) -> Self? {
        let units = Array(replacement.utf16)
        guard !units.isEmpty,
              !units.contains(where: Self.isLineSeparator),
              let displayRange = displayRange(for: range),
              units.count <= Self.maximumLength - (displayUTF16.count - displayRange.length),
              let canonical = UTF16SelectionRange.replacing(text, range: range, with: replacement),
              let display = UTF16SelectionRange.replacing(displayText, range: displayRange, with: replacement)
        else { return nil }
        let end = range.location + range.length
        let delta = units.count - range.length
        let separators = separatorOffsets.map { $0 >= end ? $0 + delta : $0 }
        return Self(
            displayUTF16: Array(display.utf16),
            textUTF16: Array(canonical.utf16),
            separatorOffsets: separators
        )
    }

    private static func isLineSeparator(_ unit: UInt16) -> Bool {
        unit == 0x000A || unit == 0x000D || unit == 0x2028 || unit == 0x2029
    }
}
#endif
