import ImrseCore
import XCTest
@testable import ImrseMac

final class ClipboardTargetStructureValidationTests: XCTestCase {
    func testAllowsEmptyTextFieldAndTextArea() {
        XCTAssertTrue(permits(Node(role: "AXTextField")))
        XCTAssertTrue(permits(Node(role: "AXTextArea")))
    }

    func testAllowsSingleGroupChainEndingInLeafStaticText() {
        let leaf = Node(role: "AXStaticText")
        let nestedGroup = Node(role: "AXGroup", children: [leaf])
        let group = Node(role: "AXGroup", children: [nestedGroup])

        XCTAssertTrue(permits(Node(role: "AXTextArea", children: [group])))
    }

    func testRejectsThreeStaticTextSegments() {
        let segments = (0..<3).map { _ in Node(role: "AXStaticText") }
        let group = Node(role: "AXGroup", children: segments)

        XCTAssertFalse(permits(Node(role: "AXTextArea", children: [group])))
    }

    func testRejectsUnknownRolesAndUnreadableRoleOrChildren() {
        XCTAssertFalse(permits(Node(role: "AXUnknown")))
        XCTAssertFalse(permits(Node(role: "AXTextField", children: [Node(role: "AXButton")])))
        XCTAssertFalse(permits(Node(role: "AXTextArea", children: [Node(role: "AXStaticText")])))
        XCTAssertFalse(permits(Node(
            role: "AXTextArea",
            children: [Node(role: "AXGroup", children: [Node(role: "AXStaticText", children: [Node(role: "AXStaticText")])])]
        )))
        XCTAssertFalse(permits(Node(role: nil)))
        XCTAssertFalse(permits(Node(role: "AXTextArea", children: nil)))
        XCTAssertFalse(permits(Node(role: "AXTextArea", children: [Node(role: "AXGroup", children: nil)])))
    }

    func testRejectsCyclesAndStructuresBeyondTheNodeBudget() {
        let cycle = Node(role: "AXGroup")
        cycle.children = [cycle]
        XCTAssertFalse(permits(Node(role: "AXTextField", children: [cycle])))
        XCTAssertTrue(permits(targetWithGroupDepth(ClipboardTargetStructureValidation.maximumNodes - 2)))
        XCTAssertFalse(permits(targetWithGroupDepth(ClipboardTargetStructureValidation.maximumNodes - 1)))
    }

    func testReclassifiesTargetThatBecomesStructuredDuringPreparation() {
        let target = Node(role: "AXTextField")
        XCTAssertTrue(permits(target))

        target.children = [Node(
            role: "AXGroup",
            children: (0..<3).map { _ in Node(role: "AXStaticText") }
        )]

        XCTAssertFalse(permits(target))
    }

    func testNativeSelectedTextConfirmationDoesNotDependOnClipboardShape() {
        let range = ImrseCore.TextRange(location: 7, length: 3)
        let structuredTarget = Node(
            role: "AXTextField",
            children: [Node(role: "AXGroup", children: (0..<3).map { _ in Node(role: "AXStaticText") })]
        )

        XCTAssertFalse(permits(structuredTarget))
        XCTAssertTrue(SelectedTextReplacementValidation.confirms(
            afterValue: nil,
            expectedValue: nil,
            afterRange: range,
            afterText: "new",
            replacementRange: range,
            replacement: "new"
        ))
    }

    private func permits(_ root: Node) -> Bool {
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

    private func targetWithGroupDepth(_ groupCount: Int) -> Node {
        var child = Node(role: "AXStaticText")
        for _ in 0..<groupCount {
            child = Node(role: "AXGroup", children: [child])
        }
        return Node(role: "AXTextArea", children: [child])
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
