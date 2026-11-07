#if os(macOS) && DEBUG
import ApplicationServices
import AppKit
import Foundation
import ImrseCore
import XCTest
@_spi(SyntheticCaptureDiagnostics) @testable import ImrseMac
@testable import ImrseApp

@MainActor
final class SyntheticCaptureAppModelTests: XCTestCase {
    func testDebugCompositionUsesTheConstrainedRealAccessForItsEngine() throws {
        let session = makeSession()
        let access = MacSelectionAccess(syntheticCaptureSession: session)
        let monitor = SyntheticTestShortcutMonitor()
        let model = try XCTUnwrap(AppModel(
            debugSyntheticCaptureAccess: access,
            textProvider: NonexecutingTextProvider(),
            shortcutMonitoring: monitor,
            permissionStatusReader: nonPromptingPermissionReader
        ))
        defer { model.endDebugSyntheticCaptureSession() }

        XCTAssertTrue(model.selectionAccess === access)
        XCTAssertEqual(session.state, .armed)
        model.engine.invoke(intent: .replaceSelection)

        XCTAssertEqual(session.state, .failed)
        XCTAssertFalse(session.retainsNativeIdentity)
    }

    func testSessionTeardownInvalidatesEpochBeforeDroppingIdentityAndNeverRestarts() throws {
        let session = makeSession()
        let access = MacSelectionAccess(syntheticCaptureSession: session)
        let monitor = SyntheticTestShortcutMonitor()
        let model = try XCTUnwrap(AppModel(
            debugSyntheticCaptureAccess: access,
            textProvider: NonexecutingTextProvider(),
            shortcutMonitoring: monitor,
            permissionStatusReader: nonPromptingPermissionReader
        ))
        let epochBeforeEnd = model.shortcutMonitorActivationEpoch
        monitor.onStop = { XCTAssertTrue(session.retainsNativeIdentity) }

        model.endDebugSyntheticCaptureSession()
        let startCountAfterEnd = monitor.startCount
        monitor.fireLateInsertion()
        model.retryKeyboardMonitoring()
        model.applicationDidBecomeActive()

        XCTAssertGreaterThan(model.shortcutMonitorActivationEpoch, epochBeforeEnd)
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertFalse(session.retainsNativeIdentity)
        XCTAssertEqual(monitor.startCount, startCountAfterEnd)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertFalse(model.canUndo)
    }

    func testApplicationTerminationCancelsSessionAfterStoppingMonitorEpoch() throws {
        let session = makeSession()
        let access = MacSelectionAccess(syntheticCaptureSession: session)
        let monitor = SyntheticTestShortcutMonitor()
        let model = try XCTUnwrap(AppModel(
            debugSyntheticCaptureAccess: access,
            textProvider: NonexecutingTextProvider(),
            shortcutMonitoring: monitor,
            permissionStatusReader: nonPromptingPermissionReader
        ))
        let epochBeforeTermination = model.shortcutMonitorActivationEpoch
        monitor.onStop = { XCTAssertTrue(session.retainsNativeIdentity) }
        var reply: NSApplication.TerminateReply?

        let result = model.requestTermination { reply = $0 }

        XCTAssertEqual(result, .terminateNow)
        XCTAssertEqual(reply, nil)
        XCTAssertGreaterThan(model.shortcutMonitorActivationEpoch, epochBeforeTermination)
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertFalse(session.retainsNativeIdentity)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertFalse(model.canUndo)
    }

    private var nonPromptingPermissionReader: PermissionStatusReader {
        PermissionStatusReader(accessibility: { false }, inputMonitoring: { false })
    }

    private func makeSession() -> SyntheticCaptureSession {
        let anchor = AXUIElementCreateSystemWide()
        let identity = SyntheticCaptureIdentity(
            processIdentifier: 41,
            processLaunchDate: Date(timeIntervalSince1970: 1_700_000_000),
            bundleIdentifier: "org.example.synthetic-editor",
            documentURL: URL(fileURLWithPath: "/synthetic/approved.txt"),
            documentRoot: anchor,
            focusedField: anchor
        )
        return SyntheticCaptureSession(identity: identity)
    }
}

@MainActor
private final class SyntheticTestShortcutMonitor: ShortcutMonitoring {
    private(set) var isMonitoring = false
    private(set) var startCount = 0
    var onStop: (() -> Void)?
    private var onInsertAtCaret: (@MainActor () -> Void)?
    private var lateInsertion: (@MainActor () -> Void)?

    func start(
        configuration: InvocationConfiguration,
        presets: [Preset],
        onInvoke: @escaping @MainActor (String?) -> Void,
        onInsertAtCaret: @escaping @MainActor () -> Void
    ) throws {
        startCount += 1
        isMonitoring = true
        self.onInsertAtCaret = onInsertAtCaret
    }

    func stop() {
        lateInsertion = onInsertAtCaret
        onStop?()
        onInsertAtCaret = nil
        isMonitoring = false
    }

    func fireLateInsertion() {
        lateInsertion?()
    }
}

private struct NonexecutingTextProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
#endif
