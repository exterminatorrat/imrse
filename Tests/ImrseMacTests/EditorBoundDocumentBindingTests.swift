import ApplicationServices
import Foundation
import ImrseCore
import XCTest
@testable import ImrseMac

final class EditorBoundDocumentBindingTests: XCTestCase {
    private static let documentURL = "https://capy.example/chat/thread"

    func testTriggerAcceptsOnlyAnEmptySuccessfulDocumentValue() {
        XCTAssertTrue(EditorBoundDocumentBinding.isEligible(documentFailure: .emptyValue))

        let refused: [DocumentContextFailure?] = [
            nil,
            .attributeUnsupported,
            .unexpectedNoValuePayload,
            .missingValue,
            .unexpectedValueType,
            .valueTooLong
        ]
        for failure in refused {
            let label = String(describing: failure)
            XCTAssertFalse(EditorBoundDocumentBinding.isEligible(documentFailure: failure), label)
        }
    }

    func testWindowDocumentStateClassifiesEveryWindowReadOutcome() {
        let overLimit = String(repeating: "x", count: SelectionTargetContextValidation.maximumDocumentUTF16Length + 1)
        let cases: [(AXError, CFTypeRef?, EditorBoundDocumentBinding.WindowDocumentState)] = [
            (.success, "" as CFString, .empty),
            (.success, "document" as CFString, .populated),
            (.success, "document-😀" as CFString, .populated),
            (.success, kCFBooleanTrue, .refused),
            (.success, nil, .refused),
            (.success, overLimit as CFString, .refused),
            (.attributeUnsupported, nil, .refused),
            (.noValue, "unexpected" as CFString, .refused),
            (.noValue, nil, .unavailable),
            (.cannotComplete, nil, .readFailed),
            (.apiDisabled, nil, .readFailed)
        ]
        for (status, value, expected) in cases {
            let label = "\(status.rawValue) \(String(describing: value))"
            XCTAssertEqual(
                EditorBoundDocumentBinding.windowDocumentState(
                    read: SelectionTargetContextValidation.documentRead(status: status, value: value),
                    failure: SelectionTargetContextValidation.documentFailure(status: status, value: value)
                ),
                expected,
                label
            )
        }
    }

    func testCaptureRoutingNeverResolvesForOtherDocumentFailures() {
        let refused: [DocumentContextFailure?] = [
            nil,
            .attributeUnsupported,
            .unexpectedNoValuePayload,
            .missingValue,
            .unexpectedValueType,
            .valueTooLong
        ]
        for failure in refused {
            var resolutions = 0
            var observations = 0
            let binding: EditorBoundDocumentBinding.Binding<Int>? = EditorBoundDocumentBinding.captureResolution(
                intent: .replaceSelection,
                documentFailure: failure,
                resolve: {
                    resolutions += 1
                    return nil
                },
                observe: { observations += 1 }
            )
            XCTAssertNil(binding)
            XCTAssertEqual(resolutions, 0, String(describing: failure))
            XCTAssertEqual(observations, 1, String(describing: failure))
        }
    }

    func testCaptureRoutingNeverResolvesForCaretInsertion() {
        var resolutions = 0
        var observations = 0
        let binding: EditorBoundDocumentBinding.Binding<Int>? = EditorBoundDocumentBinding.captureResolution(
            intent: .insertAtCaret,
            documentFailure: .emptyValue,
            resolve: {
                resolutions += 1
                return nil
            },
            observe: { observations += 1 }
        )

        XCTAssertNil(binding)
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(observations, 1)
    }

    func testCaptureRoutingResolvesBeforeAnyOptInObservation() {
        for diagnosticsEnabled in [false, true] {
            let fixture = editorFixture(url: stringSample(Self.documentURL))
            fixture.probeCheckLimit = 4
            var observations = 0
            let binding = EditorBoundDocumentBinding.captureResolution(
                intent: .replaceSelection,
                documentFailure: .emptyValue,
                resolve: { fixture.resolve(editor: 0, window: 9) },
                observe: {
                    observations += 1
                    if diagnosticsEnabled { _ = fixture.resolve(editor: 0, window: 9) }
                }
            )

            XCTAssertNotNil(binding, "diagnostics \(diagnosticsEnabled)")
            XCTAssertEqual(observations, 0, "diagnostics \(diagnosticsEnabled)")
        }
    }

    func testCaptureRoutingObservesOnlyAfterAFailedRecovery() {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        fixture.probeCheckLimit = 0
        var observations = 0
        let binding = EditorBoundDocumentBinding.captureResolution(
            intent: .replaceSelection,
            documentFailure: .emptyValue,
            resolve: { fixture.resolve(editor: 0, window: 9) },
            observe: { observations += 1 }
        )

        XCTAssertNil(binding)
        XCTAssertEqual(observations, 1)
    }

    func testResolveBindsTheNearestWebAreaAboveTheEditor() throws {
        let fixture = BindingFixture([
            node(0, role: kAXTextAreaRole as String, window: 9, parent: 1),
            node(1, window: 9, parent: 2),
            node(2, role: "AXWebArea", window: 9, parent: 3, url: stringSample(Self.documentURL)),
            node(3, role: "AXWebArea", window: 9, parent: 9, url: stringSample("https://capy.example/outer")),
            windowNode(9)
        ])

        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        XCTAssertEqual(binding.editor, 0)
        XCTAssertEqual(binding.webArea, 2)
        XCTAssertEqual(binding.url, .string(Array(Self.documentURL.utf16)))
    }

    func testResolveBindsATypedURLRepresentation() throws {
        let fixture = editorFixture(url: urlSample(Self.documentURL))

        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        XCTAssertEqual(binding.webArea, 2)
        XCTAssertEqual(binding.url, .url(Array(Self.documentURL.utf16)))
        XCTAssertNotEqual(binding.url, .string(Array(Self.documentURL.utf16)))
    }

    func testResolveBindsAWebAreaTwentySixAncestorsAboveTheEditor() throws {
        let fixture = chainFixture(depth: 26)

        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 900))

        XCTAssertEqual(binding.editor, 0)
        XCTAssertEqual(binding.webArea, 26)
        XCTAssertEqual(binding.url, .string(Array(Self.documentURL.utf16)))
    }

    func testResolveDoesNotTreatTheEditorItselfAsTheBoundWebArea() {
        let fixture = BindingFixture([
            node(0, role: "AXWebArea", window: 9, parent: 9, url: stringSample(Self.documentURL)),
            windowNode(9)
        ])

        XCTAssertNil(fixture.resolve(editor: 0, window: 9))
        XCTAssertEqual(fixture.roleReads, 0)
    }

    func testResolveRequiresABoundedNonemptyTypedURL() {
        let refused: [DocumentBindingProbe.URLSample] = [
            .init(read: .emptyString),
            .init(read: .emptyURL),
            .init(read: .missingValue),
            .init(read: .noValue),
            .init(read: .unsupported),
            .init(read: .unexpectedType),
            .init(read: .unexpectedNoValuePayload),
            .init(read: .valueTooLong),
            .init(read: .readFailed)
        ]
        for sample in refused {
            XCTAssertNil(editorFixture(url: sample).resolve(editor: 0, window: 9), "\(sample.read)")
        }

        let atLimit = String(repeating: "x", count: DocumentBindingProbe.maximumURLValueUTF16Length)
        XCTAssertNotNil(editorFixture(
            url: DocumentBindingProbe.urlSample(status: .success, value: atLimit as CFString)
        ).resolve(editor: 0, window: 9))
        XCTAssertNil(editorFixture(
            url: DocumentBindingProbe.urlSample(status: .success, value: (atLimit + "x") as CFString)
        ).resolve(editor: 0, window: 9))
    }

    func testResolveRejectsAncestryThatLeavesTheProcessOrWindow() {
        let foreignProcess = BindingFixture([
            node(0, role: kAXTextAreaRole as String, window: 9, parent: 1),
            node(1, role: "AXWebArea", window: 9, parent: 8, processID: 43, url: stringSample(Self.documentURL)),
            windowNode(8, processID: 43),
            windowNode(9)
        ])
        XCTAssertNil(foreignProcess.resolve(editor: 0, window: 9))

        let foreignWindow = BindingFixture([
            node(0, role: kAXTextAreaRole as String, window: 9, parent: 1),
            node(1, role: "AXWebArea", window: 8, parent: 9, url: stringSample(Self.documentURL)),
            windowNode(8),
            windowNode(9)
        ])
        XCTAssertNil(foreignWindow.resolve(editor: 0, window: 9))

        let missingWindow = BindingFixture([
            node(0, role: kAXTextAreaRole as String, window: 9, parent: 1),
            node(1, role: "AXWebArea", window: nil, parent: 9, url: stringSample(Self.documentURL)),
            windowNode(9)
        ])
        XCTAssertNil(missingWindow.resolve(editor: 0, window: 9))
    }

    func testResolveRejectsAForeignEditorBeforeWalking() {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        fixture.update(0) { $0.processID = 43 }

        XCTAssertNil(fixture.resolve(editor: 0, window: 9))
        XCTAssertEqual(fixture.parentReads, 0)
    }

    func testResolveRejectsUnreadableCyclicOrOversizedAncestry() {
        let parentReadFailure = editorFixture(url: stringSample(Self.documentURL))
        parentReadFailure.throwsParentRead = true
        XCTAssertNil(parentReadFailure.resolve(editor: 0, window: 9))

        let roleReadFailure = editorFixture(url: stringSample(Self.documentURL))
        roleReadFailure.throwsRoleRead = true
        XCTAssertNil(roleReadFailure.resolve(editor: 0, window: 9))

        let cycle = BindingFixture([
            node(0, role: kAXTextAreaRole as String, window: 9, parent: 1),
            node(1, window: 9, parent: 0),
            windowNode(9)
        ])
        XCTAssertNil(cycle.resolve(editor: 0, window: 9))

        XCTAssertNotNil(
            chainFixture(depth: DocumentBindingDiagnostic.maximumAncestorDepth).resolve(editor: 0, window: 900)
        )
        XCTAssertNil(
            chainFixture(depth: DocumentBindingDiagnostic.maximumAncestorDepth + 1).resolve(editor: 0, window: 900)
        )

        let exhausted = editorFixture(url: stringSample(Self.documentURL))
        exhausted.probeCheckLimit = 0
        XCTAssertNil(exhausted.resolve(editor: 0, window: 9))
        XCTAssertEqual(exhausted.parentReads, 0)
    }

    func testResolveRejectsAnEditorThatIsItsOwnWindow() {
        let fixture = BindingFixture([
            node(0, role: kAXTextAreaRole as String, window: 9, parent: 2),
            node(2, role: "AXWebArea", window: 9, parent: 9, url: stringSample(Self.documentURL)),
            windowNode(9)
        ])

        XCTAssertNil(fixture.resolve(editor: 0, window: 0))
        XCTAssertEqual(fixture.parentReads, 0)
    }

    func testResolveRejectsIntentsOtherThanReplaceSelection() {
        let fixture = editorFixture(url: stringSample(Self.documentURL))

        XCTAssertNil(fixture.resolve(editor: 0, window: 9, intent: .insertAtCaret))
        XCTAssertNotNil(fixture.resolve(editor: 0, window: 9, intent: .replaceSelection))
    }

    func testRevalidationAcceptsTheUnchangedBinding() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        XCTAssertNil(try fixture.failureReason(binding: binding, currentEditor: 0))
        XCTAssertNil(try fixture.failureReason(binding: binding, currentEditor: 0))
        XCTAssertEqual(fixture.urlReads, 3)
    }

    func testRevalidationRequiresTheWindowDocumentToRemainEmpty() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        XCTAssertNil(try fixture.failureReason(binding: binding, currentEditor: 0))

        fixture.windowDocument = .populated
        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0),
            .documentContextChanged
        )

        for state in [EditorBoundDocumentBinding.WindowDocumentState.unavailable, .refused, .readFailed] {
            fixture.windowDocument = state
            XCTAssertEqual(
                try fixture.failureReason(binding: binding, currentEditor: 0),
                .documentContextUnavailable,
                "\(state)"
            )
        }
    }

    func testRevalidationRejectsADifferentWebAreaWithAnIdenticalURL() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        fixture.insert(node(3, role: "AXWebArea", window: 9, parent: 2, url: stringSample(Self.documentURL)))
        fixture.update(1) { $0.parentID = 3 }

        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0),
            .documentContextChanged
        )
    }

    func testRevalidationRejectsAWebAreaThatIsGone() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        fixture.update(1) { $0.parentID = 9 }

        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0),
            .documentContextUnavailable
        )
    }

    func testRevalidationRejectsAChangedURLOrRepresentation() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        fixture.update(2) { $0.url = stringSample("https://capy.example/chat/other") }
        XCTAssertEqual(try fixture.failureReason(binding: binding, currentEditor: 0), .documentContextChanged)

        fixture.update(2) { $0.url = urlSample(Self.documentURL) }
        XCTAssertEqual(try fixture.failureReason(binding: binding, currentEditor: 0), .documentContextChanged)
    }

    func testRevalidationRejectsAChangedEditorBeforeTraversal() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))
        let readsAfterCapture = fixture.parentReads

        XCTAssertEqual(try fixture.failureReason(binding: binding, currentEditor: 5), .documentContextChanged)
        XCTAssertEqual(fixture.parentReads, readsAfterCapture)
    }

    func testRevalidationRejectsAForeignEditorBeforeWalking() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        fixture.update(0) { $0.processID = 43 }
        let readsAfterCapture = fixture.parentReads

        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0),
            .documentContextUnavailable
        )
        XCTAssertEqual(fixture.parentReads, readsAfterCapture)
    }

    func testRevalidationRejectsMissingChangedOrInvalidWindows() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0, currentWindow: nil),
            .windowContextUnavailable
        )
        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0, currentWindow: 8),
            .windowContextChanged
        )
        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0, validWindow: false),
            .windowContextChanged
        )
    }

    func testRevalidationRejectsUnreadableCyclicOrOversizedAncestry() throws {
        let parentReadFailure = editorFixture(url: stringSample(Self.documentURL))
        let parentBinding = try XCTUnwrap(parentReadFailure.resolve(editor: 0, window: 9))
        parentReadFailure.throwsParentRead = true
        XCTAssertEqual(
            try parentReadFailure.failureReason(binding: parentBinding, currentEditor: 0),
            .documentContextUnavailable
        )

        let roleReadFailure = editorFixture(url: stringSample(Self.documentURL))
        let roleBinding = try XCTUnwrap(roleReadFailure.resolve(editor: 0, window: 9))
        roleReadFailure.throwsRoleRead = true
        XCTAssertEqual(
            try roleReadFailure.failureReason(binding: roleBinding, currentEditor: 0),
            .documentContextUnavailable
        )

        let cycle = editorFixture(url: stringSample(Self.documentURL))
        let cycleBinding = try XCTUnwrap(cycle.resolve(editor: 0, window: 9))
        cycle.update(1) { $0.parentID = 0 }
        XCTAssertEqual(try cycle.failureReason(binding: cycleBinding, currentEditor: 0), .documentContextUnavailable)

        let deep = editorFixture(url: stringSample(Self.documentURL))
        let deepBinding = try XCTUnwrap(deep.resolve(editor: 0, window: 9))
        deep.update(2) {
            $0.role = "AXGroup"
            $0.parentID = 3
        }
        for id in 3...DocumentBindingDiagnostic.maximumAncestorDepth {
            deep.insert(node(id, window: 9, parent: id + 1))
        }
        deep.insert(node(
            DocumentBindingDiagnostic.maximumAncestorDepth + 1,
            role: "AXWebArea",
            window: 9,
            parent: 9,
            url: stringSample(Self.documentURL)
        ))
        XCTAssertEqual(try deep.failureReason(binding: deepBinding, currentEditor: 0), .documentContextUnavailable)

        let exhausted = editorFixture(url: stringSample(Self.documentURL))
        let exhaustedBinding = try XCTUnwrap(exhausted.resolve(editor: 0, window: 9))
        exhausted.probeCheckLimit = 2
        XCTAssertEqual(
            try exhausted.failureReason(binding: exhaustedBinding, currentEditor: 0),
            .documentContextUnavailable
        )
    }

    func testRevalidationRejectsAncestryFromAnotherProcess() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        fixture.update(1) { $0.processID = 43 }

        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0),
            .documentContextUnavailable
        )
    }

    func testRevalidationRejectsAnURLThatCannotBeReadAgain() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        for sample in [DocumentBindingProbe.URLSample(read: .readFailed), .init(read: .emptyString)] {
            fixture.update(2) { $0.url = sample }
            XCTAssertEqual(
                try fixture.failureReason(binding: binding, currentEditor: 0),
                .documentContextUnavailable
            )
        }
    }

    func testRevalidationRejectsIntentsOtherThanReplaceSelection() throws {
        let fixture = editorFixture(url: stringSample(Self.documentURL))
        let binding = try XCTUnwrap(fixture.resolve(editor: 0, window: 9))

        XCTAssertEqual(
            try fixture.failureReason(binding: binding, currentEditor: 0, intent: .insertAtCaret),
            .caretProofUnavailable
        )
    }

    private func editorFixture(url: DocumentBindingProbe.URLSample) -> BindingFixture {
        BindingFixture([
            node(0, role: kAXTextAreaRole as String, window: 9, parent: 1),
            node(1, window: 9, parent: 2),
            node(2, role: "AXWebArea", window: 9, parent: 9, url: url),
            windowNode(9)
        ])
    }

    private func chainFixture(depth: Int) -> BindingFixture {
        var nodes: [BindingNode] = []
        for id in 0...depth {
            nodes.append(node(
                id,
                role: id == depth ? "AXWebArea" : "AXGroup",
                window: 900,
                parent: id + 1,
                url: id == depth ? stringSample(Self.documentURL) : nil
            ))
        }
        nodes.append(windowNode(900))
        return BindingFixture(nodes)
    }
}

private func stringSample(_ value: String) -> DocumentBindingProbe.URLSample {
    DocumentBindingProbe.URLSample(read: .nonemptyString, value: .string(Array(value.utf16)))
}

private func urlSample(_ value: String) -> DocumentBindingProbe.URLSample {
    DocumentBindingProbe.URLSample(read: .nonemptyURL, value: .url(Array(value.utf16)))
}

private func node(
    _ id: Int,
    role: String = "AXGroup",
    window: Int? = 9,
    parent: Int? = nil,
    processID: Int32 = 42,
    url: DocumentBindingProbe.URLSample? = nil
) -> BindingNode {
    BindingNode(
        id: id,
        processID: processID,
        role: role,
        windowID: window,
        parentID: parent,
        url: url
    )
}

private func windowNode(_ id: Int, processID: Int32 = 42) -> BindingNode {
    BindingNode(id: id, processID: processID, role: kAXWindowRole as String, windowID: id, parentID: nil, url: nil)
}

private struct BindingNode: Equatable {
    let id: Int
    var processID: Int32
    var role: String
    var windowID: Int?
    var parentID: Int?
    var url: DocumentBindingProbe.URLSample?
}

private final class BindingFixture {
    private(set) var nodes: [Int: BindingNode]
    private(set) var parentReads = 0
    private(set) var roleReads = 0
    private(set) var urlReads = 0
    var windowDocument = EditorBoundDocumentBinding.WindowDocumentState.empty
    var probeCheckLimit = Int.max
    var throwsParentRead = false
    var throwsRoleRead = false
    private var probeChecks = 0

    init(_ nodes: [BindingNode]) {
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    func insert(_ node: BindingNode) {
        nodes[node.id] = node
    }

    func update(_ id: Int, _ mutate: (inout BindingNode) -> Void) {
        guard var node = nodes[id] else { return }
        mutate(&node)
        nodes[id] = node
    }

    func resolve(
        editor: Int,
        window: Int,
        intent: SelectionEditIntent = .replaceSelection
    ) -> EditorBoundDocumentBinding.Binding<Int>? {
        EditorBoundDocumentBinding.resolve(
            editor: editor,
            window: window,
            intent: intent,
            hasTimeForProbe: hasTimeForProbe,
            isSameProcess: isSameProcess,
            readParent: readParent,
            readRole: readRole,
            readWindow: readWindow,
            readURL: readURL,
            sameElement: { $0 == $1 }
        )
    }

    func failureReason(
        binding: EditorBoundDocumentBinding.Binding<Int>,
        currentEditor: Int,
        currentWindow: Int? = 9,
        intent: SelectionEditIntent = .replaceSelection,
        validWindow: Bool = true
    ) throws -> SelectionFailureReason? {
        try EditorBoundDocumentBinding.failureReason(
            binding: binding,
            currentEditor: currentEditor,
            capturedWindow: 9,
            currentWindow: currentWindow,
            intent: intent,
            sameElement: { $0 == $1 },
            isValidWindow: { _ in validWindow },
            readWindowDocumentState: { self.windowDocument },
            hasTimeForProbe: hasTimeForProbe,
            isSameProcess: isSameProcess,
            readParent: readParent,
            readRole: readRole,
            readWindow: readWindow,
            readURL: readURL
        )
    }

    private func hasTimeForProbe() -> Bool {
        probeChecks += 1
        return probeChecks <= probeCheckLimit
    }

    private func isSameProcess(_ id: Int) -> Bool {
        nodes[id]?.processID == 42
    }

    private func readParent(_ id: Int) throws -> Int? {
        parentReads += 1
        if throwsParentRead { throw BindingTestError.readFailed }
        return nodes[id]?.parentID
    }

    private func readRole(_ id: Int) throws -> String? {
        roleReads += 1
        if throwsRoleRead { throw BindingTestError.readFailed }
        return nodes[id]?.role
    }

    private func readWindow(_ id: Int) throws -> Int? {
        nodes[id]?.windowID
    }

    private func readURL(_ id: Int) -> DocumentBindingProbe.URLSample {
        urlReads += 1
        return nodes[id].flatMap(\.url) ?? DocumentBindingProbe.URLSample(read: .noValue)
    }
}

private enum BindingTestError: Error {
    case readFailed
}
