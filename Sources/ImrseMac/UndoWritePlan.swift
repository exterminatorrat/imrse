import ImrseCore

/// Inverse transport is fixed by the successful receipt, never rediscovered
/// from today's capabilities or host qualification. A refusal is terminal.
struct UndoWritePlan {
    let strategy: ReplacementStrategy

    @MainActor
    func perform(
        selectedText: () async throws -> Void,
        valueRange: () async throws -> Void,
        clipboard: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        switch strategy {
        case .selectedText: try await selectedText()
        case .valueRange: try await valueRange()
        case .clipboard: try await clipboard()
        }
    }
}

/// Private, in-memory proof. Never serialized into diagnostic reports.
struct UndoValueProof {
    let original: String
    let applied: String

    static func make(original: String?, applied: String?) -> Self? {
        guard let original, let applied else { return nil }
        return Self(original: original, applied: applied)
    }

    func confirmsApplied(_ current: String?) -> Bool {
        current.map { $0.utf16.elementsEqual(applied.utf16) } ?? false
    }
}

/// Rechecked at the text-write boundary, including after async preparation.
enum SelectionMutationGate {
    static func requireAllowed(strategy: ReplacementStrategy, clipboardEnabled: Bool) throws {
        try Task.checkCancellation()
        if strategy == .clipboard && !clipboardEnabled { throw ImrseError.clipboardFailed }
    }
}
