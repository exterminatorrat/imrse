#if os(macOS) && DEBUG
import AppKit
import Foundation
import ImrseCore
import ImrseMac
import ImrseServices
import XCTest
@testable import ImrseApp

@MainActor
final class PermissionStatusRefreshTests: XCTestCase {
    func testAuthorizationAndRuntimeActivityRemainSeparateAndRefreshOnActivation() {
        let permissions = TestPermissionValues(accessibility: false, inputMonitoring: true)
        let monitor = TestPermissionShortcutMonitor()
        let model = makeModel(permissions: permissions, monitor: monitor)

        XCTAssertEqual(model.accessibilityStatus, "Not authorized")
        XCTAssertEqual(model.inputMonitoringStatus, "Allowed")
        XCTAssertEqual(model.eventMonitoringStatus, "Active")

        model.applicationDidResignActive()
        permissions.accessibility = true
        permissions.inputMonitoring = false
        model.applicationDidBecomeActive()

        XCTAssertEqual(model.accessibilityStatus, "Allowed")
        XCTAssertEqual(model.inputMonitoringStatus, "Not authorized")
        XCTAssertEqual(model.eventMonitoringStatus, "Active")
        XCTAssertTrue(model.keyboardMonitoringDetail.contains("Input Monitoring isn't authorized"))
        XCTAssertEqual(monitor.startCount, 1)
    }

    func testAllowedInputMonitoringDoesNotClaimAnInactiveTapIsActive() {
        let permissions = TestPermissionValues(accessibility: true, inputMonitoring: true)
        let monitor = TestPermissionShortcutMonitor()
        let model = makeModel(permissions: permissions, monitor: monitor)

        monitor.disable()
        model.refreshPermissionStatus()

        XCTAssertEqual(model.inputMonitoringStatus, "Allowed")
        XCTAssertEqual(model.eventMonitoringStatus, "Inactive")
        XCTAssertTrue(model.keyboardMonitoringDetail.contains("Keyboard monitoring is inactive"))
    }

    func testTapFailureAndDisabledActivationPreferenceHaveAccurateReasons() {
        let permissions = TestPermissionValues(accessibility: true, inputMonitoring: true)
        let failedMonitor = TestPermissionShortcutMonitor(failure: ShortcutMonitorError.eventTapCreationFailed)
        let failedModel = makeModel(permissions: permissions, monitor: failedMonitor)

        XCTAssertEqual(failedModel.inputMonitoringStatus, "Allowed")
        XCTAssertEqual(failedModel.eventMonitoringStatus, "Unavailable")
        XCTAssertTrue(failedModel.keyboardMonitoringDetail.contains("Keyboard monitoring couldn't start"))

        var configuration = AppConfiguration()
        configuration.invocation.doubleControlEnabled = false
        let activeModel = makeModel(
            permissions: permissions,
            monitor: TestPermissionShortcutMonitor(),
            configuration: configuration
        )

        XCTAssertEqual(activeModel.eventMonitoringStatus, "Active")
        XCTAssertTrue(activeModel.keyboardMonitoringDetail.contains("No keyboard activation is enabled"))
    }

    func testVisibleRefreshIsCoalescedAndCancelsOnHideAndTermination() async {
        let permissions = TestPermissionValues(accessibility: true, inputMonitoring: true)
        let monitor = TestPermissionShortcutMonitor()
        let model = makeModel(permissions: permissions, monitor: monitor, interval: .milliseconds(15))
        let startCount = monitor.startCount

        model.settingsWindowVisibilityChanged(isVisible: true)
        XCTAssertTrue(model.isPermissionStatusRefreshing)
        let openedReadCount = permissions.readCount
        model.settingsWindowVisibilityChanged(isVisible: true)
        XCTAssertEqual(permissions.readCount, openedReadCount)

        await waitUntil { permissions.readCount > openedReadCount }
        XCTAssertEqual(monitor.startCount, startCount)
        model.settingsWindowVisibilityChanged(isVisible: false)
        XCTAssertFalse(model.isPermissionStatusRefreshing)
        let hiddenReadCount = permissions.readCount
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(permissions.readCount, hiddenReadCount)

        model.settingsWindowVisibilityChanged(isVisible: true)
        let resumedReadCount = permissions.readCount
        model.applicationDidResignActive()
        XCTAssertFalse(model.isPermissionStatusRefreshing)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(permissions.readCount, resumedReadCount)

        model.applicationDidBecomeActive()
        XCTAssertTrue(model.isPermissionStatusRefreshing)
        let termination = model.requestTermination { _ in }
        XCTAssertEqual(termination, .terminateNow)
        XCTAssertFalse(model.isPermissionStatusRefreshing)
        let terminatedReadCount = permissions.readCount
        model.applicationDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(permissions.readCount, terminatedReadCount)
        XCTAssertEqual(model.eventMonitoringStatus, "Unavailable")
        XCTAssertEqual(monitor.startCount, startCount)
    }

    func testNonKeyWindowOrderOutAndFrontUpdateRefreshVisibility() async {
        let permissions = TestPermissionValues(accessibility: true, inputMonitoring: true)
        let model = makeModel(
            permissions: permissions,
            monitor: TestPermissionShortcutMonitor(),
            interval: .milliseconds(15)
        )
        let coordinator = AppCoordinator(model: model)
        let window = SettingsVisibilityTestWindow()
        coordinator.observeSettingsWindowVisibility(window)
        defer {
            window.orderOut(nil)
            model.settingsWindowVisibilityChanged(isVisible: false)
        }

        let initialReadCount = permissions.readCount
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        await waitUntil { permissions.readCount > initialReadCount }
        XCTAssertTrue(model.isPermissionStatusRefreshing)

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(model.isPermissionStatusRefreshing)
        let hiddenReadCount = permissions.readCount
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(permissions.readCount, hiddenReadCount)

        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        await waitUntil { permissions.readCount > hiddenReadCount }
        XCTAssertTrue(model.isPermissionStatusRefreshing)

        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(model.isPermissionStatusRefreshing)
    }

    func testDeferredResignAfterActivationKeepsFreshVisibleRefreshSession() {
        let permissions = TestPermissionValues(accessibility: true, inputMonitoring: true)
        let model = makeModel(
            permissions: permissions,
            monitor: TestPermissionShortcutMonitor(),
            interval: .seconds(2)
        )
        let coordinator = AppCoordinator(model: model)
        model.applicationDidResignActive()
        model.settingsWindowVisibilityChanged(isVisible: true)
        XCTAssertFalse(model.isPermissionStatusRefreshing)

        var applicationIsActive = false
        let deferredResign = {
            coordinator.reconcileDeferredApplicationResign(isApplicationActive: applicationIsActive)
        }
        applicationIsActive = true
        model.applicationDidBecomeActive()
        XCTAssertTrue(model.isPermissionStatusRefreshing)
        deferredResign()
        XCTAssertTrue(model.isPermissionStatusRefreshing)

        model.settingsWindowVisibilityChanged(isVisible: false)
    }

    func testRecordingPauseAndResumeReflectRuntimeActivity() throws {
        let permissions = TestPermissionValues()
        let model = makeModel(permissions: permissions, monitor: TestPermissionShortcutMonitor())
        let sessionID = try XCTUnwrap(model.beginShortcutRecording())

        XCTAssertEqual(model.eventMonitoringStatus, "Paused while recording")
        XCTAssertEqual(model.keyboardMonitoringDetail, "Paused while recording a keyboard shortcut.")

        model.endShortcutRecording(sessionID)
        XCTAssertEqual(model.eventMonitoringStatus, "Active")
    }

    private func makeModel(
        permissions: TestPermissionValues,
        monitor: TestPermissionShortcutMonitor = TestPermissionShortcutMonitor(),
        configuration: AppConfiguration = AppConfiguration(),
        interval: Duration = .seconds(2)
    ) -> AppModel {
        let engine = TransformationEngine(
            selectionAccess: TestPermissionSelectionAccess(),
            textProvider: TestPermissionTextProvider()
        )
        let reader = PermissionStatusReader(
            accessibility: { [weak permissions] in
                permissions?.readCount += 1
                return permissions?.accessibility ?? false
            },
            inputMonitoring: { [weak permissions] in
                permissions?.readCount += 1
                return permissions?.inputMonitoring ?? false
            }
        )
        let clock = PermissionStatusRefreshClock(interval: interval) { duration in
            try await Task.sleep(for: duration)
        }
        return AppModel(
            testEngine: engine,
            configuration: configuration,
            shortcutMonitoring: monitor,
            permissionStatusReader: reader,
            permissionStatusRefreshClock: clock
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for permission refresh", file: file, line: line)
    }
}

@MainActor
private final class TestPermissionValues {
    var accessibility: Bool
    var inputMonitoring: Bool
    var readCount = 0

    init(accessibility: Bool = false, inputMonitoring: Bool = false) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }
}

@MainActor
private final class TestPermissionShortcutMonitor: ShortcutMonitoring {
    private(set) var isMonitoring = false
    private(set) var startCount = 0
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    func start(
        configuration: InvocationConfiguration,
        presets: [Preset],
        onInvoke: @escaping @MainActor (String?) -> Void
    ) throws {
        startCount += 1
        if let failure { throw failure }
        isMonitoring = true
    }

    func stop() {
        isMonitoring = false
    }

    func disable() {
        isMonitoring = false
    }
}

@MainActor
private final class TestPermissionSelectionAccess: SelectionAccess {
    private let selection = SelectionSnapshot(applicationID: "test", processID: 1, role: "textField", text: "test")

    func capture() throws -> SelectionSnapshot { selection }
    func validate(_ target: SelectionSnapshot) throws {}
    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }
    func undo(_ receipt: ReplacementReceipt) async throws {}
    func discard(_ target: SelectionSnapshot) {}
}

private struct TestPermissionTextProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class SettingsVisibilityTestWindow: SettingsWindow {
    override var canBecomeKey: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }
}
#endif
