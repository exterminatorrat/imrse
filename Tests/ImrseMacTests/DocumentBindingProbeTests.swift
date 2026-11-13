import ApplicationServices
import Foundation
import ImrseCore
import XCTest
@testable import ImrseMac

final class DocumentBindingProbeTests: XCTestCase {
    func testObservationFindsTheWebAreaAboveTheEditor() {
        let fixture = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: 1),
            probeNode(1, parent: 2),
            probeNode(2, role: "AXWebArea", parent: 9),
            probeWindow(9)
        ])

        let observation = fixture.observe(editor: 0, window: 9)

        XCTAssertEqual(observation.result, .foundWebArea)
        XCTAssertEqual(observation.depth, 2)
        XCTAssertEqual(observation.candidate?.id, 2)
    }

    func testObservationAcceptsAWebAreaEditorAtDepthZero() {
        let fixture = ProbeFixture([
            probeNode(0, role: "AXWebArea", parent: 9),
            probeWindow(9)
        ])

        let observation = fixture.observe(editor: 0, window: 9)

        XCTAssertEqual(observation.result, .foundWebArea)
        XCTAssertEqual(observation.depth, 0)
        XCTAssertEqual(fixture.parentReads, 0)
    }

    func testObservationStopsAtTheCapturedWindowWithoutReadingItsOwnRole() {
        let fixture = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: 9),
            probeWindow(9)
        ])

        let observation = fixture.observe(editor: 0, window: 9)

        XCTAssertEqual(observation.result, .notFound)
        XCTAssertNil(observation.depth)
        XCTAssertNil(observation.candidate)
        XCTAssertEqual(fixture.parentReads, 1)
        XCTAssertEqual(fixture.roleReads, 1)
    }

    func testObservationReportsAMissingParentAsNotFound() {
        let fixture = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: nil),
            probeWindow(9)
        ])

        XCTAssertEqual(fixture.observe(editor: 0, window: 9).result, .notFound)
    }

    func testObservationDetectsAnAncestorCycle() {
        let fixture = ProbeFixture([
            probeNode(0, parent: 1),
            probeNode(1, parent: 0),
            probeWindow(9)
        ])

        XCTAssertEqual(fixture.observe(editor: 0, window: 9).result, .cycleDetected)
    }

    func testObservationHonoursTheSharedDepthBound() {
        let atLimit = chainFixture(depth: DocumentBindingDiagnostic.maximumAncestorDepth)
        let foundObservation = atLimit.observe(editor: 0, window: 900)
        XCTAssertEqual(foundObservation.result, .foundWebArea)
        XCTAssertEqual(foundObservation.depth, DocumentBindingDiagnostic.maximumAncestorDepth)

        let beyondLimit = chainFixture(depth: DocumentBindingDiagnostic.maximumAncestorDepth + 1)
        XCTAssertEqual(beyondLimit.observe(editor: 0, window: 900).result, .depthLimitReached)
    }

    func testObservationStopsWhenTheCaptureBudgetIsExhausted() {
        let beforeAnyRead = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: 1),
            probeNode(1, parent: 9),
            probeWindow(9)
        ])
        beforeAnyRead.probeCheckLimit = 0
        XCTAssertEqual(beforeAnyRead.observe(editor: 0, window: 9).result, .timeLimitReached)
        XCTAssertEqual(beforeAnyRead.parentReads, 0)

        let midWalk = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: 1),
            probeNode(1, parent: 9),
            probeWindow(9)
        ])
        midWalk.probeCheckLimit = 2
        XCTAssertEqual(midWalk.observe(editor: 0, window: 9).result, .timeLimitReached)
        XCTAssertEqual(midWalk.parentReads, 0)
    }

    func testObservationReportsThrownAncestorReads() {
        let parentFailure = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: 1),
            probeNode(1, parent: 9),
            probeWindow(9)
        ])
        parentFailure.throwsParentRead = true
        XCTAssertEqual(parentFailure.observe(editor: 0, window: 9).result, .readFailed)

        let roleFailure = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: 1),
            probeNode(1, parent: 9),
            probeWindow(9)
        ])
        roleFailure.throwsRoleRead = true
        XCTAssertEqual(roleFailure.observe(editor: 0, window: 9).result, .readFailed)

        let windowFailure = ProbeFixture([
            probeNode(0, parent: 1),
            probeNode(1, role: "AXWebArea", parent: 9),
            probeWindow(9)
        ])
        windowFailure.throwsWindowRead = true
        XCTAssertEqual(windowFailure.observe(editor: 0, window: 9).result, .readFailed)
    }

    func testObservationTreatsAnUnobservedRoleAsAReadFailure() {
        let editorRole = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: 1),
            probeNode(1, parent: 9),
            probeWindow(9)
        ])
        editorRole.missingRoleIDs = [0]
        XCTAssertEqual(editorRole.observe(editor: 0, window: 9).result, .readFailed)

        let ancestorRole = ProbeFixture([
            probeNode(0, role: kAXTextAreaRole as String, parent: 1),
            probeNode(1, parent: 9),
            probeWindow(9)
        ])
        ancestorRole.missingRoleIDs = [1]
        XCTAssertEqual(ancestorRole.observe(editor: 0, window: 9).result, .readFailed)
    }

    func testObservationRejectsAncestorsFromAnotherProcess() {
        let fixture = ProbeFixture([
            probeNode(0, parent: 1),
            probeNode(1, parent: 9, processID: 43),
            probeWindow(9)
        ])

        XCTAssertEqual(fixture.observe(editor: 0, window: 9).result, .inconsistentProcess)
    }

    func testObservationRejectsAWebAreaWithoutTheCapturedWindow() {
        let missing = ProbeFixture([
            probeNode(0, parent: 1),
            probeNode(1, role: "AXWebArea", window: nil, parent: 9),
            probeWindow(9)
        ])
        XCTAssertEqual(missing.observe(editor: 0, window: 9).result, .inconsistentWindow)

        let foreign = ProbeFixture([
            probeNode(0, parent: 1),
            probeNode(1, role: "AXWebArea", window: 8, parent: 9),
            probeNode(8, role: kAXWindowRole as String, parent: nil),
            probeWindow(9)
        ])
        XCTAssertEqual(foreign.observe(editor: 0, window: 9).result, .inconsistentWindow)

        let otherProcess = ProbeFixture([
            probeNode(0, parent: 1),
            probeNode(1, role: "AXWebArea", window: 8, parent: 9),
            probeNode(8, role: kAXWindowRole as String, parent: nil, processID: 43),
            probeWindow(9)
        ])
        XCTAssertEqual(otherProcess.observe(editor: 0, window: 9).result, .inconsistentProcess)
    }

    func testURLSampleClassifiesStatusAndPayloadWithoutRetainingIt() {
        XCTAssertEqual(
            DocumentBindingProbe.urlSample(status: .attributeUnsupported, value: nil),
            .init(read: .unsupported)
        )
        XCTAssertEqual(DocumentBindingProbe.urlSample(status: .noValue, value: nil), .init(read: .noValue))
        XCTAssertEqual(
            DocumentBindingProbe.urlSample(status: .noValue, value: "unexpected" as CFString),
            .init(read: .unexpectedNoValuePayload)
        )
        XCTAssertEqual(DocumentBindingProbe.urlSample(status: .cannotComplete, value: nil), .init(read: .readFailed))
        XCTAssertEqual(DocumentBindingProbe.urlSample(status: .success, value: nil), .init(read: .missingValue))
        XCTAssertEqual(
            DocumentBindingProbe.urlSample(status: .success, value: kCFBooleanTrue),
            .init(read: .unexpectedType)
        )
        XCTAssertEqual(
            DocumentBindingProbe.urlSample(status: .success, value: "" as CFString),
            .init(read: .emptyString)
        )
    }

    func testURLSampleRetainsExactUnitsForStringsAndURLs() throws {
        let string = "https://example.com/document"
        let stringSample = DocumentBindingProbe.urlSample(status: .success, value: string as CFString)
        XCTAssertEqual(stringSample.read, .nonemptyString)
        XCTAssertEqual(stringSample.value, .string(Array(string.utf16)))

        let url = try XCTUnwrap(CFURLCreateWithString(kCFAllocatorDefault, string as CFString, nil))
        let urlSample = DocumentBindingProbe.urlSample(status: .success, value: url)
        let absolute = try XCTUnwrap((url as NSURL).absoluteString)
        XCTAssertEqual(urlSample.read, .nonemptyURL)
        XCTAssertEqual(urlSample.value, .url(Array(absolute.utf16)))
        XCTAssertNotEqual(stringSample.value, urlSample.value)
    }

    func testURLSampleBoundsRetainedUnits() {
        let atLimit = String(repeating: "x", count: DocumentBindingProbe.maximumURLValueUTF16Length)
        let atLimitSample = DocumentBindingProbe.urlSample(status: .success, value: atLimit as CFString)
        XCTAssertEqual(atLimitSample.read, .nonemptyString)
        XCTAssertEqual(atLimitSample.value, .string(Array(atLimit.utf16)))

        let overLimit = atLimit + "x"
        XCTAssertEqual(
            DocumentBindingProbe.urlSample(status: .success, value: overLimit as CFString),
            .init(read: .valueTooLong)
        )
    }

    func testComparisonRequiresOnePreviousSnapshotFromTheSameProcess() {
        let current: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 42,
            window: 9,
            editor: 2,
            webArea: 3,
            value: .string([65])
        )
        XCTAssertNil(DocumentBindingProbe.comparison(
            previous: nil,
            current: current,
            sameElement: { $0 == $1 }
        ))

        let otherProcess: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 43,
            window: 9,
            editor: 2,
            webArea: 3,
            value: .string([65])
        )
        XCTAssertNil(DocumentBindingProbe.comparison(
            previous: otherProcess,
            current: current,
            sameElement: { $0 == $1 }
        ))
    }

    func testComparisonReportsEqualityForTheSameObservedIdentity() throws {
        let previous: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 42,
            window: 9,
            editor: 2,
            webArea: 3,
            value: .string([65])
        )
        let identical: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 42,
            window: 9,
            editor: 2,
            webArea: 3,
            value: .string([65])
        )
        let comparison = try XCTUnwrap(DocumentBindingProbe.comparison(
            previous: previous,
            current: identical,
            sameElement: { $0 == $1 }
        ))

        XCTAssertEqual(comparison.windowUnchanged, true)
        XCTAssertEqual(comparison.editorUnchanged, true)
        XCTAssertEqual(comparison.webAreaUnchanged, true)
        XCTAssertEqual(comparison.urlUnchanged, true)
    }

    func testComparisonDistinguishesRepresentationEvenForEqualUnits() {
        let previous: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 42,
            window: 9,
            editor: 2,
            webArea: 3,
            value: .string([65])
        )
        let replaced: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 42,
            window: 10,
            editor: 4,
            webArea: 5,
            value: .url([65])
        )
        let comparison = DocumentBindingProbe.comparison(
            previous: previous,
            current: replaced,
            sameElement: { $0 == $1 }
        )

        XCTAssertEqual(comparison?.windowUnchanged, false)
        XCTAssertEqual(comparison?.editorUnchanged, false)
        XCTAssertEqual(comparison?.webAreaUnchanged, false)
        XCTAssertEqual(comparison?.urlUnchanged, false)
    }

    func testComparisonLeavesUnobservedIdentityUnknown() {
        let previous: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 42,
            window: 9,
            editor: 2,
            webArea: nil,
            value: .string([65])
        )
        let current: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 42,
            window: 9,
            editor: 2,
            webArea: 3,
            value: nil
        )
        let comparison = DocumentBindingProbe.comparison(
            previous: previous,
            current: current,
            sameElement: { $0 == $1 }
        )

        XCTAssertEqual(comparison?.windowUnchanged, true)
        XCTAssertEqual(comparison?.editorUnchanged, true)
        XCTAssertNil(comparison?.webAreaUnchanged)
        XCTAssertNil(comparison?.urlUnchanged)
    }

    func testCacheIsKeptOnlyBetweenCapturesThatProducedASample() {
        let snapshot: DocumentBindingProbe.Snapshot<Int> = .init(
            processID: 42,
            window: 9,
            editor: 2,
            webArea: 3,
            value: .string([65])
        )
        let noPrevious: DocumentBindingProbe.Snapshot<Int>? = nil
        let sample = DocumentBindingDiagnostic(ancestorResult: .notFound)

        XCTAssertNil(DocumentBindingProbe.snapshotAfterCapture(noPrevious, diagnostic: sample))
        XCTAssertNil(DocumentBindingProbe.snapshotAfterCapture(snapshot, diagnostic: nil))
        XCTAssertEqual(
            DocumentBindingProbe.snapshotAfterCapture(snapshot, diagnostic: sample)?.editor,
            2
        )
    }

    @MainActor
    func testAccessExposesNoBindingObservationWithoutAProbeRun() {
        XCTAssertNil(MacSelectionAccess().lastDocumentBindingDiagnostic)
        XCTAssertNil(MacSelectionAccess(
            clipboardFallbackEnabled: false,
            documentBindingDiagnosticsEnabled: true
        ).lastDocumentBindingDiagnostic)
    }

    private func chainFixture(depth: Int) -> ProbeFixture {
        var nodes: [ProbeNode] = []
        for id in 0...depth {
            nodes.append(probeNode(
                id,
                role: id == depth ? "AXWebArea" : "AXGroup",
                window: 900,
                parent: id + 1
            ))
        }
        nodes.append(probeWindow(900))
        return ProbeFixture(nodes)
    }
}

private struct ProbeNode: Equatable {
    let id: Int
    let processID: Int32
    let role: String
    let windowID: Int?
    let parentID: Int?
}

private func probeNode(
    _ id: Int,
    role: String = "AXGroup",
    window: Int? = 9,
    parent: Int? = nil,
    processID: Int32 = 42
) -> ProbeNode {
    ProbeNode(id: id, processID: processID, role: role, windowID: window, parentID: parent)
}

private func probeWindow(_ id: Int, processID: Int32 = 42) -> ProbeNode {
    ProbeNode(
        id: id,
        processID: processID,
        role: kAXWindowRole as String,
        windowID: id,
        parentID: nil
    )
}

private final class ProbeFixture {
    let nodes: [Int: ProbeNode]
    private(set) var probeChecks = 0
    private(set) var parentReads = 0
    private(set) var roleReads = 0
    var probeCheckLimit = Int.max
    var throwsParentRead = false
    var throwsRoleRead = false
    var throwsWindowRead = false
    var missingRoleIDs: Set<Int> = []

    init(_ nodes: [ProbeNode]) {
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    func hasTimeForProbe() -> Bool {
        probeChecks += 1
        return probeChecks <= probeCheckLimit
    }

    func isSameProcess(_ node: ProbeNode) -> Bool {
        node.processID == 42
    }

    func readParent(_ node: ProbeNode) throws -> ProbeNode? {
        parentReads += 1
        if throwsParentRead { throw ProbeTestError.readFailed }
        return node.parentID.flatMap { nodes[$0] }
    }

    func readRole(_ node: ProbeNode) throws -> String? {
        roleReads += 1
        if throwsRoleRead { throw ProbeTestError.readFailed }
        return missingRoleIDs.contains(node.id) ? nil : node.role
    }

    func readWindow(_ node: ProbeNode) throws -> ProbeNode? {
        if throwsWindowRead { throw ProbeTestError.readFailed }
        return node.windowID.flatMap { nodes[$0] }
    }

    func observe(editor: Int, window: Int) -> DocumentBindingProbe.Observation<ProbeNode> {
        DocumentBindingProbe.observe(
            editor: node(editor),
            window: node(window),
            hasTimeForProbe: hasTimeForProbe,
            isSameProcess: isSameProcess,
            readParent: readParent,
            readRole: readRole,
            readWindow: readWindow,
            sameElement: { $0.id == $1.id }
        )
    }

    private func node(_ id: Int) -> ProbeNode {
        nodes[id]!
    }
}

private enum ProbeTestError: Error {
    case readFailed
}
