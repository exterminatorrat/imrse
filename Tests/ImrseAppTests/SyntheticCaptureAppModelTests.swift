#if os(macOS)
import ApplicationServices
import AppKit
import Foundation
import ImrseCore
import ImrsePillUI
import XCTest
@_spi(SyntheticCaptureDiagnostics) @testable import ImrseMac
@testable import ImrseApp

@MainActor
final class SyntheticCaptureDiagnosticsAvailabilityTests: XCTestCase {
    func testAppModelDiagnosticAvailabilityMatchesTheTargetBuildSetting() {
#if IMRSE_SYNTHETIC_CAPTURE_DIAGNOSTICS
        XCTAssertTrue(AppModel.syntheticCaptureDiagnosticsBuildEnabled)
#else
        XCTAssertFalse(AppModel.syntheticCaptureDiagnosticsBuildEnabled)
#endif
    }
}

#if DEBUG
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
#endif

#if IMRSE_SYNTHETIC_CAPTURE_DIAGNOSTICS
@MainActor
final class SyntheticCaptureAppModelDiagnosticTests: XCTestCase {
    func testBusyDiagnosticRefusesWithoutStoppingMonitoringOrArming() throws {
        let (ordinaryAccess, ordinarySession) = makeAccess(bundleIdentifier: "org.example.synthetic-owner")
        let (diagnosticAccess, diagnosticSession) = makeAccess()
        let monitor = SyntheticTestShortcutMonitor()
        let model = try makeModel(access: ordinaryAccess, monitor: monitor)
        defer { model.endDebugSyntheticCaptureSession() }
        let initialStartCount = monitor.startCount
        model.pillModel.present()
        var factoryCalls = 0

        model.beginSyntheticCaptureDiagnostics { _ in
            factoryCalls += 1
            return diagnosticAccess
        }

        XCTAssertEqual(model.syntheticCaptureDiagnosticsStatus, .busy)
        XCTAssertFalse(model.syntheticCaptureDiagnosticsIsLatched)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(ordinarySession.state, .armed)
        XCTAssertEqual(diagnosticSession.state, .armed)
        XCTAssertEqual(monitor.startCount, initialStartCount)
        XCTAssertTrue(monitor.isMonitoring)
        model.pillModel.dismiss()
        monitor.stop()
    }

    func testExpiredBoundSessionRefusesBeforeNativeAccessViaInsertionHandler() async throws {
        let (ordinaryAccess, ordinarySession) = makeAccess(bundleIdentifier: "org.example.synthetic-owner")
        let (diagnosticAccess, diagnosticSession) = makeExpiredAccess()
        let monitor = SyntheticTestShortcutMonitor()
        let provider = SyntheticCaptureProviderTripwire()
        let model = try makeModel(access: ordinaryAccess, monitor: monitor, provider: provider)
        defer { model.endDebugSyntheticCaptureSession() }
        let initialEpoch = model.shortcutMonitorActivationEpoch
        let initialStartCount = monitor.startCount
        var presentationCount = 0
        model.onPresentPill = { _ in presentationCount += 1 }

        model.beginSyntheticCaptureDiagnostics { _ in diagnosticAccess }

        XCTAssertEqual(model.syntheticCaptureDiagnosticsStatus, .waitingForTarget)
        XCTAssertFalse(model.canOpenSettings)
        XCTAssertGreaterThan(model.shortcutMonitorActivationEpoch, initialEpoch)
        XCTAssertFalse(monitor.isMonitoring)
        monitor.fireLateInsertion()
        XCTAssertEqual(diagnosticSession.state, .armed)

        model.applicationDidResignActive()
        XCTAssertEqual(model.syntheticCaptureDiagnosticsStatus, .waitingForTarget)
        XCTAssertEqual(diagnosticSession.state, .armed)
        model.handleSyntheticCaptureDiagnosticsActivation(
            processIdentifier: 42,
            processLaunchDate: Date(timeIntervalSince1970: 1_700_000_000),
            bundleIdentifier: "com.example.Other"
        )
        XCTAssertEqual(model.syntheticCaptureDiagnosticsStatus, .waitingForTarget)
        XCTAssertEqual(diagnosticSession.state, .armed)
        model.handleSyntheticCaptureDiagnosticsActivation(
            processIdentifier: 41,
            processLaunchDate: Date(timeIntervalSince1970: 1_700_000_000),
            bundleIdentifier: "com.apple.TextEdit"
        )

        XCTAssertEqual(model.syntheticCaptureDiagnosticsStatus, .unavailable)
        XCTAssertEqual(diagnosticSession.state, .failed)
        XCTAssertFalse(diagnosticSession.retainsNativeIdentity)
        XCTAssertEqual(ordinarySession.state, .armed)
        XCTAssertTrue(model.selectionAccess === ordinaryAccess)
        XCTAssertEqual(presentationCount, 0)
        XCTAssertEqual(monitor.startCount, initialStartCount)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canOpenSettings)
        XCTAssertFalse(model.canChangeSettings)

        model.invoke()
        model.handleShortcutMonitorCallback(presetID: nil, activationEpoch: model.shortcutMonitorActivationEpoch)
        model.handleInsertAtCaretShortcutMonitorCallback(activationEpoch: model.shortcutMonitorActivationEpoch)
        model.undo()
        XCTAssertFalse(model.selectPillPreset(at: 0))
        model.retryKeyboardMonitoring()
        model.applicationDidBecomeActive()
        model.pillModel.present()
        model.pillModel.applyPreset(at: 0)
        model.pillModel.submit()
        XCTAssertEqual(model.engine.state, .idle)

        let streamCalls = await provider.streamCalls
        XCTAssertEqual(streamCalls, 0)
        XCTAssertEqual(monitor.startCount, initialStartCount)
        XCTAssertFalse(monitor.isMonitoring)
    }

    func testOptInDisarmsThePriorSubmitCallbackWithValidPresetInput() throws {
        let (ordinaryAccess, ordinarySession) = makeAccess(bundleIdentifier: "org.example.synthetic-owner")
        let (diagnosticAccess, diagnosticSession) = makeAccess()
        let monitor = SyntheticTestShortcutMonitor()
        let model = try makeModel(access: ordinaryAccess, monitor: monitor)
        defer { model.endDebugSyntheticCaptureSession() }
        var previousSubmitCalls = 0
        var accessFactoryCalls = 0
        model.pillModel.onSubmit = { _ in previousSubmitCalls += 1 }

        model.beginSyntheticCaptureDiagnostics { _ in
            accessFactoryCalls += 1
            return diagnosticAccess
        }

        XCTAssertEqual(model.syntheticCaptureDiagnosticsStatus, .waitingForTarget)
        XCTAssertEqual(accessFactoryCalls, 1)
        model.pillModel.present()
        model.pillModel.applyPreset(at: 0)
        XCTAssertEqual(model.pillModel.selectedPresetID, "synthetic-preset")
        XCTAssertEqual(model.pillModel.instruction, "Synthetic capture check")
        model.pillModel.submit()

        XCTAssertNotNil(model.pillModel.phase.activeRequestID)
        XCTAssertEqual(previousSubmitCalls, 0)
        XCTAssertEqual(model.engine.state, .idle)
        XCTAssertEqual(ordinarySession.state, .armed)
        XCTAssertEqual(diagnosticSession.state, .armed)
        model.cancelPendingSyntheticCaptureDiagnostics()
    }

    func testPendingDiagnosticTimeoutCancelsSessionAndNeverRestartsMonitor() async throws {
        let (ordinaryAccess, ordinarySession) = makeAccess(bundleIdentifier: "org.example.synthetic-owner")
        let (diagnosticAccess, diagnosticSession) = makeAccess()
        let monitor = SyntheticTestShortcutMonitor()
        let model = try makeModel(access: ordinaryAccess, monitor: monitor, deadlineWaiter: { _ in })
        defer { model.endDebugSyntheticCaptureSession() }
        let initialStartCount = monitor.startCount

        model.beginSyntheticCaptureDiagnostics { _ in diagnosticAccess }
        await Task.yield()

        XCTAssertEqual(model.syntheticCaptureDiagnosticsStatus, .timedOut)
        XCTAssertEqual(diagnosticSession.state, .cancelled)
        XCTAssertFalse(diagnosticSession.retainsNativeIdentity)
        XCTAssertEqual(ordinarySession.state, .armed)
        model.applicationDidResignActive()
        model.retryKeyboardMonitoring()
        model.applicationDidBecomeActive()
        XCTAssertEqual(monitor.startCount, initialStartCount)
        XCTAssertFalse(monitor.isMonitoring)
    }

    func testPendingDiagnosticCancelAndTerminationReleaseSession() throws {
        let (cancelledOrdinaryAccess, cancelledOrdinarySession) = makeAccess(bundleIdentifier: "org.example.synthetic-owner")
        let (cancelledDiagnosticAccess, cancelledDiagnosticSession) = makeAccess()
        let cancelledMonitor = SyntheticTestShortcutMonitor()
        let cancelledModel = try makeModel(
            access: cancelledOrdinaryAccess,
            monitor: cancelledMonitor
        )
        defer { cancelledModel.endDebugSyntheticCaptureSession() }
        cancelledModel.beginSyntheticCaptureDiagnostics { _ in cancelledDiagnosticAccess }
        cancelledModel.cancelPendingSyntheticCaptureDiagnostics()
        XCTAssertEqual(cancelledModel.syntheticCaptureDiagnosticsStatus, .cancelled)
        XCTAssertEqual(cancelledDiagnosticSession.state, .cancelled)
        XCTAssertEqual(cancelledOrdinarySession.state, .armed)
        cancelledModel.applicationDidResignActive()
        XCTAssertFalse(cancelledMonitor.isMonitoring)

        let (terminatedOrdinaryAccess, terminatedOrdinarySession) = makeAccess(bundleIdentifier: "org.example.synthetic-owner")
        let (terminatedDiagnosticAccess, terminatedDiagnosticSession) = makeAccess()
        let terminatedMonitor = SyntheticTestShortcutMonitor()
        let terminatedModel = try makeModel(
            access: terminatedOrdinaryAccess,
            monitor: terminatedMonitor
        )
        defer { terminatedModel.endDebugSyntheticCaptureSession() }
        terminatedModel.beginSyntheticCaptureDiagnostics { _ in terminatedDiagnosticAccess }
        terminatedMonitor.onStop = {
            XCTAssertEqual(terminatedOrdinarySession.state, .armed)
            XCTAssertEqual(terminatedDiagnosticSession.state, .armed)
        }
        let result = terminatedModel.requestTermination { _ in }

        XCTAssertEqual(result, .terminateNow)
        XCTAssertEqual(terminatedModel.syntheticCaptureDiagnosticsStatus, .cancelled)
        XCTAssertEqual(terminatedDiagnosticSession.state, .cancelled)
        XCTAssertFalse(terminatedDiagnosticSession.retainsNativeIdentity)
        XCTAssertEqual(terminatedOrdinarySession.state, .cancelled)
        XCTAssertFalse(terminatedMonitor.isMonitoring)
    }

#if DEBUG
    func testCompletedRetainedRefreshHandleDoesNotBlockButActiveRefreshDoes() async throws {
        let completedRefresh = Task<Void, Never> {}
        await completedRefresh.value
        let (ordinaryAccess, ordinarySession) = makeAccess(bundleIdentifier: "org.example.synthetic-owner")
        let (diagnosticAccess, diagnosticSession) = makeAccess()
        let monitor = SyntheticTestShortcutMonitor()
        let model = try makeModel(access: ordinaryAccess, monitor: monitor)
        defer { model.endDebugSyntheticCaptureSession() }
        model.setChatGPTRefreshStateForTesting(task: completedRefresh, isRefreshing: false)

        model.beginSyntheticCaptureDiagnostics { _ in diagnosticAccess }

        XCTAssertEqual(model.syntheticCaptureDiagnosticsStatus, .waitingForTarget)
        XCTAssertEqual(ordinarySession.state, .armed)
        XCTAssertEqual(diagnosticSession.state, .armed)
        model.cancelPendingSyntheticCaptureDiagnostics()

        let (activeOrdinaryAccess, activeOrdinarySession) = makeAccess(bundleIdentifier: "org.example.synthetic-owner")
        let (unusedDiagnosticAccess, unusedDiagnosticSession) = makeAccess()
        let activeMonitor = SyntheticTestShortcutMonitor()
        let activeModel = try makeModel(access: activeOrdinaryAccess, monitor: activeMonitor)
        defer { activeModel.endDebugSyntheticCaptureSession() }
        let activeRefresh = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
        }
        activeModel.setChatGPTRefreshStateForTesting(task: activeRefresh, isRefreshing: true)
        var factoryCalls = 0

        activeModel.beginSyntheticCaptureDiagnostics { _ in
            factoryCalls += 1
            return unusedDiagnosticAccess
        }

        XCTAssertEqual(activeModel.syntheticCaptureDiagnosticsStatus, .busy)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(activeOrdinarySession.state, .armed)
        XCTAssertEqual(unusedDiagnosticSession.state, .armed)
        activeRefresh.cancel()
        activeModel.setChatGPTRefreshStateForTesting(task: nil, isRefreshing: false)
    }

    func testDiagnosticAdmissionUsesLiveRefreshFlagNotTaskHandlePresence() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/ImrseApp/App/AppModel.swift")
            .standardizedFileURL
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    private var canBeginSyntheticCaptureDiagnostics: Bool {"))
        let end = try XCTUnwrap(source.range(of: "\n    private func finishSyntheticCaptureDiagnostics(", range: start.upperBound..<source.endIndex))
        let admission = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(admission.contains("&& !isRefreshingChatGPTAccount"))
        XCTAssertFalse(admission.contains("accountStatusRefreshTask"))
    }
#endif

    private func makeModel(
        access: MacSelectionAccess,
        monitor: SyntheticTestShortcutMonitor,
        deadlineWaiter: (@MainActor (ContinuousClock.Instant) async throws -> Void)? = nil
    ) throws -> AppModel {
        let providerConfiguration = ProviderConfiguration(
            id: "synthetic-provider",
            name: "Synthetic provider",
            kind: .compatible,
            endpoint: URL(string: "https://synthetic.example.test/v1")!,
            model: "synthetic-model",
            requiresCredential: false
        )
        return try XCTUnwrap(AppModel(
            debugSyntheticCaptureAccess: access,
            textProvider: SyntheticCaptureProviderTripwire(),
            configuration: AppConfiguration(
                providers: [providerConfiguration],
                selectedProviderID: providerConfiguration.id
            ),
            presets: [Preset(
                id: "synthetic-preset",
                name: "Synthetic preset",
                instruction: "Synthetic capture check",
                providerID: providerConfiguration.id
            )],
            shortcutMonitoring: monitor,
            permissionStatusReader: PermissionStatusReader(accessibility: { false }, inputMonitoring: { false }),
            deadlineWaiter: deadlineWaiter
        ))
    }

    private func makeExpiredAccess() -> (access: MacSelectionAccess, session: SyntheticCaptureSession) {
        var instant = ContinuousClock().now
        let accessAndSession = makeAccess(now: { instant })
        instant = instant.advanced(by: .seconds(31))
        return accessAndSession
    }

    private func makeAccess(
        processIdentifier: Int32 = 41,
        bundleIdentifier: String = SyntheticCaptureFixtureContract.bundleIdentifier,
        documentURL: URL = URL(fileURLWithPath: "/synthetic/approved.txt"),
        lifetime: Duration = .seconds(30),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) -> (access: MacSelectionAccess, session: SyntheticCaptureSession) {
        let anchor = AXUIElementCreateSystemWide()
        let identity = SyntheticCaptureIdentity(
            processIdentifier: processIdentifier,
            processLaunchDate: Date(timeIntervalSince1970: 1_700_000_000),
            bundleIdentifier: bundleIdentifier,
            documentURL: documentURL,
            documentRoot: anchor,
            focusedField: anchor
        )
        let session = SyntheticCaptureSession(identity: identity, lifetime: lifetime, now: now)
        return (MacSelectionAccess(syntheticCaptureSession: session), session)
    }
}

private enum SyntheticCaptureProviderTripwireError: Error {
    case invoked
}

private actor SyntheticCaptureProviderTripwire: TextProvider {
    private(set) var streamCalls = 0

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        streamCalls += 1
        throw SyntheticCaptureProviderTripwireError.invoked
    }
}
#endif

#if DEBUG || IMRSE_SYNTHETIC_CAPTURE_DIAGNOSTICS
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
#endif
