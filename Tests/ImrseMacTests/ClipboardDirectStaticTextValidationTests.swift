import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct ClipboardDirectStaticTextValidationTests {
    @Test
    func permitsOnlyOneDirectChildlessStaticText() {
        let root = Node(role: "AXTextArea", children: [Node(role: "AXStaticText")])

        #expect(permitsDirectStaticText(root))
    }

    @Test
    func rejectsOtherRolesAndShapes() {
        #expect(!permitsDirectStaticText(Node(role: "AXTextField")))
        #expect(!permitsDirectStaticText(Node(role: "AXTextArea")))
        #expect(!permitsDirectStaticText(Node(
            role: "AXTextArea",
            children: [Node(role: "AXStaticText"), Node(role: "AXStaticText")]
        )))
        #expect(!permitsDirectStaticText(Node(
            role: "AXTextArea",
            children: [Node(role: "AXStaticText", children: [Node(role: "AXStaticText")])]
        )))
        #expect(!permitsDirectStaticText(Node(role: "AXTextArea", children: [Node(role: "AXGroup")])))
        #expect(!permitsDirectStaticText(Node(role: "AXUnknown", children: [Node(role: "AXStaticText")])))
        #expect(!permitsDirectStaticText(Node(role: "AXTextArea", children: [Node(role: "AXUnknown")])))
        #expect(!permitsDirectStaticText(Node(role: "AXTextArea", children: [Node(role: "AXTextArea")])))
    }

    @Test
    func rejectsUnreadableTypeEquivalentAndCyclicElements() {
        #expect(!permitsDirectStaticText(Node(role: nil, children: [Node(role: "AXStaticText")])))
        #expect(!permitsDirectStaticText(Node(role: "AXTextArea", children: nil)))
        #expect(!permitsDirectStaticText(Node(
            role: "AXTextArea",
            children: [Node(role: "AXStaticText", children: nil)]
        )))

        let equivalentRoot = Node(role: "AXTextArea", children: [Node(role: "AXStaticText")])
        #expect(!permitsDirectStaticText(equivalentRoot, sameElement: { _, _ in true }))

        let rootCycle = Node(role: "AXTextArea")
        rootCycle.children = [rootCycle]
        #expect(!permitsDirectStaticText(rootCycle))

        let leafCycle = Node(role: "AXStaticText")
        leafCycle.children = [leafCycle]
        #expect(!permitsDirectStaticText(Node(role: "AXTextArea", children: [leafCycle])))
    }

    @Test
    func reclassifiesAnElementWhoseShapeChanges() {
        let root = Node(role: "AXTextArea", children: [Node(role: "AXStaticText")])

        #expect(permitsDirectStaticText(root))
        root.children = [Node(role: "AXGroup")]
        #expect(!permitsDirectStaticText(root))
    }

    @Test
    func legacyStructureValidationStillRefusesTheDirectStaticTextRoot() {
        let root = Node(role: "AXTextArea", children: [Node(role: "AXStaticText")])

        #expect(!permitsLegacyClipboardStructure(root))
    }

    private func permitsDirectStaticText(
        _ root: Node,
        sameElement: (Node, Node) -> Bool = { $0 === $1 }
    ) -> Bool {
        ClipboardDirectStaticTextValidation.permits(
            root: root,
            readRole: { node in
                guard let role = node.role else { throw ReadError.unavailable }
                return role
            },
            readChildren: { node in
                guard let children = node.children else { throw ReadError.unavailable }
                return children
            },
            sameElement: sameElement
        )
    }

    private func permitsLegacyClipboardStructure(_ root: Node) -> Bool {
        ClipboardTargetStructureValidation.permits(
            root: root,
            readRole: { node in
                guard let role = node.role else { throw ReadError.unavailable }
                return role
            },
            readChildren: { node in
                guard let children = node.children else { throw ReadError.unavailable }
                return children
            },
            sameElement: { $0 === $1 }
        )
    }

    private enum ReadError: Error {
        case unavailable
    }

    private final class Node {
        let role: String?
        var children: [Node]?

        init(role: String?, children: [Node]? = []) {
            self.role = role
            self.children = children
        }
    }
}
