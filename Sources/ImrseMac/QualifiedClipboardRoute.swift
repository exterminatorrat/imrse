import ImrseCore

/// Qualification only selects a candidate route; the complete clipboard safety
/// transaction remains mandatory before any pasteboard staging or mutation.
enum QualifiedClipboardRoute {
    static func isCandidate(enabled: Bool, applicationID: String, role: String,
                            intent: SelectionEditIntent) -> Bool {
        enabled && intent == .replaceSelection
            && ["com.apple.Safari", "com.vivaldi.Vivaldi", "ai.capy.desktop"].contains(applicationID)
            && ["AXTextField", "AXTextArea"].contains(role)
    }
    static func prefersClipboard(enabled: Bool, applicationID: String, role: String,
                                 intent: SelectionEditIntent, verifiedWebArea: Bool) -> Bool {
        isCandidate(enabled: enabled, applicationID: applicationID, role: role, intent: intent)
            && verifiedWebArea
    }
    static func verifiesWebArea<Node>(root: Node, hasBudget: () -> Bool,
        same: (Node, Node) -> Bool, isSameProcessAndWindow: (Node) throws -> Bool,
        isWebArea: (Node) throws -> Bool, parent: (Node) throws -> Node?) -> Bool {
        var current = root
        var visited: [Node] = []
        do {
            for _ in 0..<32 {
                guard hasBudget(), !visited.contains(where: { same($0, current) }),
                      try isSameProcessAndWindow(current), hasBudget() else { return false }
                visited.append(current)
                if try isWebArea(current) { return hasBudget() }
                guard hasBudget(), let next = try parent(current) else { return false }
                current = next
            }
        } catch { return false }
        return false
    }
}
