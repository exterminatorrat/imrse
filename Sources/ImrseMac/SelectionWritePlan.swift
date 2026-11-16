import ImrseCore

/// Select exactly one route before dispatch. A route preference does not waive
/// that route's full target, selection, style and ownership preflight.
enum SelectionWritePlan {
    static func choose(
        prefersQualifiedClipboard: Bool,
        clipboardEnabled: Bool,
        selectedTextSettable: () throws -> Bool,
        wholeValueAvailable: Bool,
        valueSettable: () throws -> Bool
    ) throws -> ReplacementStrategy? {
        if prefersQualifiedClipboard && clipboardEnabled { return .clipboard }
        if try selectedTextSettable() { return .selectedText }
        if wholeValueAvailable, try valueSettable() { return .valueRange }
        return clipboardEnabled ? .clipboard : nil
    }
}
