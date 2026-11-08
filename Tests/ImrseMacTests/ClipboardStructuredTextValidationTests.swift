#if os(macOS)
import Testing
@testable import ImrseMac

@Suite
struct ClipboardStructuredTextValidationTests {
    @Test
    func projectsOnlyOrderedInertLeavesInsideTheField() throws {
        let root = Node("AXTextArea", children: [
            Node("AXGroup", children: [Node("AXStaticText", text: "alpha "), Node("AXStaticText", text: "beta")]),
            Node("AXGroup", children: [Node("AXStaticText", text: "gamma")])
        ])
        let result = try #require(project(root, display: "alpha beta\ngamma"))
        #expect(result.text == "alpha betagamma")
        #expect(result.separatorOffsets == [10])
        #expect(project(root, display: "alpha beta gamma") == nil)
        root.children.reverse()
        #expect(project(root, display: "alpha beta\ngamma") == nil)
    }

    @Test(arguments: ["AXTextField", "AXTextArea", "AXButton", "AXLink", "AXUnknown"])
    func rejectsInteractiveAndUnknownDescendants(_ role: String) {
        let root = Node("AXTextArea", children: [Node("AXStaticText", text: "a"), Node(role, text: "b")])
        #expect(project(root, display: "ab") == nil)
    }

    @Test
    func rejectsForeignUnparentedSharedAndUnreadableNodes() {
        let leaf = Node("AXStaticText", text: "b")
        let root = Node("AXTextArea", children: [Node("AXStaticText", text: "a"), leaf])
        #expect(project(root, display: "ab") != nil)
        leaf.inProcess = false
        #expect(project(root, display: "ab") == nil)
        leaf.inProcess = true
        leaf.parent = nil
        #expect(project(root, display: "ab") == nil)
        leaf.parent = root
        leaf.readable = false
        #expect(project(root, display: "ab") == nil)
        leaf.readable = true
        root.children.append(leaf)
        #expect(project(root, display: "abb") == nil)
        root.children = [root]
        #expect(project(root, display: "ab") == nil)
        root.children = []
    }

    @Test
    func rejectsUnboundedEmptyAndNonleafStructures() {
        let wide = Node("AXTextArea", children: (0..<64).map { _ in Node("AXStaticText", text: "a") })
        #expect(project(wide, display: String(repeating: "a", count: 64)) == nil)
        var deep = Node("AXGroup", children: [Node("AXStaticText", text: "a"), Node("AXStaticText", text: "b")])
        for _ in 0..<10 { deep = Node("AXGroup", children: [deep]) }
        #expect(project(Node("AXTextArea", children: [deep]), display: "ab") == nil)
        #expect(project(Node("AXTextArea", children: [Node("AXGroup")]), display: "a") == nil)
        #expect(project(Node("AXTextArea", children: [Node("AXStaticText", text: "a")]), display: "a") == nil)
        let nonleaf = Node("AXStaticText", text: "a", children: [Node("AXStaticText", text: "a")])
        #expect(project(Node("AXTextArea", children: [nonleaf, Node("AXStaticText", text: "b")]), display: "ab") == nil)
    }

    private func project(_ root: Node, display: String) -> ContenteditableTextProjection? {
        ClipboardStructuredTextValidation.projection(
            root: root,
            displayText: display,
            readRole: { $0.role },
            readChildren: {
                guard $0.readable else { throw ReadError.unavailable }
                return $0.children
            },
            readText: { $0.text },
            readParent: { $0.parent },
            belongsToProcess: { $0.inProcess },
            sameElement: { $0 === $1 }
        )
    }

    private enum ReadError: Error { case unavailable }

    private final class Node {
        let role: String
        let text: String?
        var children: [Node]
        weak var parent: Node?
        var inProcess = true
        var readable = true

        init(_ role: String, text: String? = nil, children: [Node] = []) {
            self.role = role
            self.text = text
            self.children = children
            for child in children { child.parent = self }
        }
    }
}
#endif
