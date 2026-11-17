import Foundation
import ImrseCore

/// Conservative negative signals, not proof that unmarked surfaces are safe.
/// Never uses document text, titles, URLs or source-code contents.
/// Class names are content-controlled and may change; these are deny hints only.
/// Generic/localized "editor" descriptions alone do not identify a proxy.
enum EditorSurfaceScope {
    enum Classification: Equatable {
        case recognizedProxy
        case notIdentified
    }

    static func classify(applicationID: String, roleDescription: String?, domClasses: [String]) -> Classification {
        if applicationID == "com.microsoft.VSCode" { return .recognizedProxy }
        let description = roleDescription?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if description == "code editor" { return .recognizedProxy }
        let classes = Set(domClasses)
        // Observed Obsidian Live Preview CodeMirror surface. Do not generalize
        // this content-controlled token to unrelated hosts or ordinary fields.
        if applicationID == "md.obsidian", classes.contains("cm-content") { return .recognizedProxy }
        if classes.contains("monaco-editor") || classes.contains("native-edit-context")
            || (classes.contains("inputarea") && classes.contains("monaco-mouse-cursor-text")) {
            return .recognizedProxy
        }
        return .notIdentified
    }

    static func decodeDOMClasses(_ raw: Any?) throws -> [String] {
        guard let array = raw as? NSArray, array.count <= 64 else { throw ImrseError.unsupportedEditor }
        var classes: [String] = []
        for item in array {
            guard let item = item as? String, item.utf16.count <= 256 else { throw ImrseError.unsupportedEditor }
            classes.append(item)
        }
        return classes
    }

    static func requireBoundedDescription(_ description: String?) throws {
        guard description.map({ $0.utf16.count <= 256 }) ?? true else { throw ImrseError.unsupportedEditor }
    }

    static func requireAllowed(applicationID: String, roleDescription: String?, domClasses: [String]) throws {
        guard classify(applicationID: applicationID, roleDescription: roleDescription, domClasses: domClasses) != .recognizedProxy else {
            throw ImrseError.unsupportedEditor
        }
    }
}
