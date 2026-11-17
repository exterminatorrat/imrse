import XCTest
import ImrseCore
@testable import ImrseMac

final class EditorSurfaceScopeTests: XCTestCase {
    func testObservedCodeHostRefusesEvenWithoutMarkers() {
        XCTAssertEqual(EditorSurfaceScope.classify(applicationID: "com.microsoft.VSCode", roleDescription: nil, domClasses: []), .recognizedProxy)
    }

    func testProxyMarkersRefuseInsideOtherwiseQualifiedBrowserHosts() {
        for host in ["com.google.Chrome", "com.apple.Safari", "com.vivaldi.Vivaldi"] {
            for marker in ["native-edit-context", "monaco-editor"] {
                XCTAssertEqual(EditorSurfaceScope.classify(applicationID: host, roleDescription: "text entry area", domClasses: ["other", marker]), .recognizedProxy)
            }
        }
    }

    func testClassicMonacoRequiresTheSpecificClassPair() {
        XCTAssertEqual(EditorSurfaceScope.classify(applicationID: "com.google.Chrome", roleDescription: nil, domClasses: ["inputarea", "monaco-mouse-cursor-text"]), .recognizedProxy)
        for classes in [["inputarea"], ["monaco-mouse-cursor-text"], ["inputarea", "unrelated"]] {
            XCTAssertEqual(EditorSurfaceScope.classify(applicationID: "com.google.Chrome", roleDescription: nil, domClasses: classes), .notIdentified)
        }
    }

    func testDOMClassDecodeRejectsMalformedOrUnboundedMetadata() throws {
        XCTAssertEqual(try EditorSurfaceScope.decodeDOMClasses([]), [])
        XCTAssertEqual(try EditorSurfaceScope.decodeDOMClasses(["native-edit-context"]), ["native-edit-context"])
        XCTAssertEqual(try EditorSurfaceScope.decodeDOMClasses(Array(repeating: "a", count: 64)).count, 64)
        for raw in [nil, "inputarea", 7, ["ok", 7] as [Any], Array(repeating: "a", count: 65), [String(repeating: "a", count: 257)]] as [Any?] {
            XCTAssertThrowsError(try EditorSurfaceScope.decodeDOMClasses(raw))
        }
        XCTAssertEqual(try EditorSurfaceScope.decodeDOMClasses([String(repeating: "a", count: 256)]).count, 1)
    }

    func testDescriptionBoundUsesUTF16AndAllowsAbsentOptionalAttribute() throws {
        try EditorSurfaceScope.requireBoundedDescription(nil)
        try EditorSurfaceScope.requireBoundedDescription(String(repeating: "a", count: 256))
        XCTAssertThrowsError(try EditorSurfaceScope.requireBoundedDescription(String(repeating: "a", count: 257)))
        XCTAssertThrowsError(try EditorSurfaceScope.requireBoundedDescription(String(repeating: "😀", count: 129)))
    }

    func testUnmarkedOrdinaryFieldsAreNotCertifiedButRetainExistingPolicy() {
        for host in ["com.apple.TextEdit", "com.google.Chrome", "com.apple.Safari", "com.microsoft.Word"] {
            for description in [nil, "text entry area", "editor", "éditeur"] as [String?] {
                XCTAssertEqual(EditorSurfaceScope.classify(applicationID: host, roleDescription: description, domClasses: []), .notIdentified)
            }
        }
        XCTAssertEqual(EditorSurfaceScope.classify(applicationID: "other", roleDescription: nil, domClasses: ["inputarea-wrapper", "not-monaco-editor"]), .notIdentified)
    }

    func testExplicitCodeEditorDescriptionIsConservativeNegativeSignal() {
        XCTAssertEqual(EditorSurfaceScope.classify(applicationID: "other", roleDescription: " Code Editor ", domClasses: []), .recognizedProxy)
    }

    @MainActor
    func testVerifiedActionRefusalDispatchesNothing() {
        var writes = 0
        XCTAssertThrowsError(try VerifiedAction.perform(verify: {
            try EditorSurfaceScope.requireAllowed(applicationID: "com.google.Chrome", roleDescription: "editor", domClasses: ["native-edit-context"])
        }, action: { writes += 1 })) { XCTAssertEqual($0 as? ImrseError, .unsupportedEditor) }
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testEveryPinnedInverseRouteStopsAtSurfaceRefusalWithoutAlternateDispatch() async {
        for strategy in [ReplacementStrategy.selectedText, .valueRange, .clipboard] {
            var writes = 0
            let action = {
                try VerifiedAction.perform(verify: {
                    try EditorSurfaceScope.requireAllowed(applicationID: "com.microsoft.VSCode", roleDescription: nil, domClasses: [])
                }, action: { writes += 1 })
            }
            do {
                try await UndoWritePlan(strategy: strategy).perform(selectedText: action, valueRange: action, clipboard: action)
                XCTFail("Expected terminal refusal")
            } catch { XCTAssertEqual(error as? ImrseError, .unsupportedEditor) }
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testOrdinaryFieldStillDispatchesExactlyOnceAfterExistingVerification() throws {
        var writes = 0
        try VerifiedAction.perform(verify: {
            try EditorSurfaceScope.requireAllowed(applicationID: "com.google.Chrome", roleDescription: "text entry area", domClasses: [])
        }, action: { writes += 1 })
        XCTAssertEqual(writes, 1)
    }
}
