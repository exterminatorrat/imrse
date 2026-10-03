import Foundation

public enum ActivityWords {
    public static let standard = ["Thinking", "Refining", "Rewriting", "Polishing", "Discombobulating"]
    /// Activity copy only: these are not assertions about hidden model operations.
    public static func word(at elapsed: TimeInterval, words: [String] = standard, interval: TimeInterval = 2.5) -> String {
        guard !words.isEmpty else { return "Thinking" }
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let safeInterval = interval.isFinite && interval >= 1 ? interval : 2.5
        // Remainder before conversion also avoids trapping on extremely large elapsed values.
        let index = Int(floor(safeElapsed / safeInterval).truncatingRemainder(dividingBy: Double(words.count)))
        return words[index].isEmpty ? "Thinking" : words[index]
    }
}

/// Same four-fast / two-slow sequence as the published React component.
public struct SpiralCycle: Sendable {
    public enum Phase: String, Sendable { case fast, slow }
    public private(set) var phase: Phase = .fast
    public private(set) var completedRepeats = 0
    public init() {}
    public mutating func complete() {
        completedRepeats += 1
        let limit = phase == .fast ? 4 : 2
        if completedRepeats == limit {
            completedRepeats = 0
            phase = phase == .fast ? .slow : .fast
        }
    }
}
