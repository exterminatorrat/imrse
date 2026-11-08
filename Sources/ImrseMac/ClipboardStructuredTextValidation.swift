#if os(macOS)
import Foundation

enum ClipboardStructuredTextValidation {
    static let maximumNodes = 64
    static let maximumDepth = 10

    static func projection<Element>(
        root: Element,
        displayText: String,
        readRole: (Element) throws -> String,
        readChildren: (Element) throws -> [Element],
        readText: (Element) throws -> String?,
        readParent: (Element) throws -> Element?,
        belongsToProcess: (Element) -> Bool,
        sameElement: (Element, Element) -> Bool
    ) -> ContenteditableTextProjection? {
        var visited: [Element] = []
        var leafTexts: [String] = []
        var hasBranching = false

        func visit(_ element: Element, parent: Element?, depth: Int) throws -> Bool {
            guard depth < maximumDepth,
                  visited.count < maximumNodes,
                  !visited.contains(where: { sameElement($0, element) }),
                  belongsToProcess(element)
            else { return false }
            visited.append(element)
            if let parent {
                guard let actualParent = try readParent(element), sameElement(actualParent, parent) else {
                    return false
                }
            }
            let role = try readRole(element)
            guard parent == nil ? role == "AXTextArea" : role == "AXGroup" || role == "AXStaticText" else {
                return false
            }
            let children = try readChildren(element)
            guard children.count <= maximumNodes - visited.count else { return false }
            if role == "AXStaticText" {
                guard children.isEmpty, let text = try readText(element), !text.isEmpty else { return false }
                leafTexts.append(text)
                return true
            }
            guard !children.isEmpty else { return false }
            hasBranching = hasBranching || children.count > 1
            for child in children {
                guard try visit(child, parent: element, depth: depth + 1) else { return false }
            }
            return true
        }

        do {
            guard try visit(root, parent: nil, depth: 0), hasBranching, leafTexts.count > 1 else { return nil }
            return ContenteditableTextProjection(displayText: displayText, leafTexts: leafTexts)
        } catch {
            return nil
        }
    }
}
#endif
