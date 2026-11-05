#if os(macOS) && DEBUG
import AppKit
import Foundation
import ImrseCore
@testable import ImrseMac
import ImrseServices
import XCTest
@testable import ImrseApp

@MainActor
final class ShortcutMonitorRecoveryTests: XCTestCase {
    func testCustomShortcutPersistsDuringRecordingWithoutMonitoringPermission() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "imrse-shortcut-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(root: root)
        try store.bootstrap()
        let model = AppModel(
            testEngine: TransformationEngine(
                selectionAccess: TestSelectionAccess(),
                textProvider: EmptyTextProvider()
            ),
            configurationStore: store
        )
        let session = try XCTUnwrap(model.beginShortcutRecording())
        let shortcut = ShortcutBinding(keyCode: 40, option: true, control: true)
        var updated = model.configuration
        updated.invocation.shortcut = shortcut

        try model.saveConfiguration(updated)
        model.endShortcutRecording(session)

        XCTAssertEqual(model.configuration.invocation.shortcut, shortcut)
        XCTAssertEqual(try store.load().invocation.shortcut, shortcut)
        XCTAssertFalse(model.isRecordingShortcut)
        XCTAssertFalse(model.shortcutMonitor.isMonitoring)
    }

    func testInitialInputMonitoringDenialCanBeRetried() {
        let monitor = TestShortcutMonitor(startFailures: [.inputMonitoringPermissionRequired])
        let model = makeModel(monitor: monitor)

        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertTrue(model.shortcutIssue?.contains("Input Monitoring") == true)
        XCTAssertFalse(model.shortcutIssue?.contains("Allow Accessibility") == true)

        model.retryKeyboardMonitoring()

        XCTAssertEqual(monitor.startCount, 2)
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertNil(model.shortcutIssue)

        model.applicationDidBecomeActive()

        XCTAssertEqual(monitor.startCount, 2)
    }

    func testApplicationActivationRetriesAnInactiveMonitor() {
        let monitor = TestShortcutMonitor(startFailures: [.inputMonitoringPermissionRequired])
        let model = makeModel(monitor: monitor)

        model.applicationDidBecomeActive()

        XCTAssertEqual(monitor.startCount, 2)
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertNil(model.shortcutIssue)
    }

    func testRetryWaitsUntilShortcutRecordingEnds() throws {
        let monitor = TestShortcutMonitor(startFailures: [.inputMonitoringPermissionRequired])
        let model = makeModel(monitor: monitor)
        let sessionID = try XCTUnwrap(model.beginShortcutRecording())

        model.retryKeyboardMonitoring()

        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertFalse(model.canRetryKeyboardMonitoring)

        model.endShortcutRecording(sessionID)

        XCTAssertEqual(monitor.startCount, 2)
        XCTAssertTrue(monitor.isMonitoring)
    }

    func testRetryWaitsUntilProcessingEnds() async {
        let monitor = TestShortcutMonitor(startFailures: [.inputMonitoringPermissionRequired])
        let provider = HoldingTextProvider()
        let model = makeModel(monitor: monitor, textProvider: provider)
        model.invoke()
        model.pillModel.submit()
        await waitUntil { model.engine.state == .generating && provider.hasPendingStream }
        XCTAssertTrue(model.isProcessing)
        XCTAssertFalse(model.canRetryKeyboardMonitoring)

        model.retryKeyboardMonitoring()

        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertFalse(monitor.isMonitoring)

        provider.finish(with: "updated text")
        await waitUntil { model.engine.state == .succeeded(unchanged: false) && monitor.startCount == 2 }

        XCTAssertTrue(monitor.isMonitoring)
    }

    func testRetryWaitsUntilUndoProcessingEnds() async {
        let monitor = TestShortcutMonitor(startFailures: [.inputMonitoringPermissionRequired])
        let provider = HoldingTextProvider()
        let selection = TestSelectionAccess(holdUndo: true)
        let model = makeModel(monitor: monitor, textProvider: provider, selectionAccess: selection)
        model.invoke()
        model.pillModel.submit()
        await waitUntil { model.engine.state == .generating && provider.hasPendingStream }
        provider.finish(with: "updated text")
        await waitUntil { model.engine.state == .succeeded(unchanged: false) }
        XCTAssertTrue(model.engine.canUndo)

        model.undo()
        await waitUntil { model.engine.state == .undoing }
        XCTAssertFalse(model.canRetryKeyboardMonitoring)
        model.retryKeyboardMonitoring()

        XCTAssertTrue(model.isProcessing)
        XCTAssertEqual(monitor.startCount, 1)

        selection.finishUndo()
        await waitUntil { !model.isProcessing && monitor.startCount == 2 }

        XCTAssertTrue(monitor.isMonitoring)
    }

    func testRetryCannotRestartMonitoringAfterTermination() {
        let monitor = TestShortcutMonitor(startFailures: [.inputMonitoringPermissionRequired])
        let model = makeModel(monitor: monitor)

        XCTAssertEqual(model.requestTermination { _ in }, .terminateNow)
        model.retryKeyboardMonitoring()
        model.applicationDidBecomeActive()

        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertFalse(monitor.isMonitoring)
    }

    func testPreviewAndTestEngineWithoutFakeDoNotStartMonitoring() {
        let preview = AppModel(previewState: .settings)
        let testEngine = TransformationEngine(selectionAccess: TestSelectionAccess(), textProvider: EmptyTextProvider())
        let testModel = AppModel(testEngine: testEngine)

        for model in [preview, testModel] {
            model.retryKeyboardMonitoring()
            model.applicationDidBecomeActive()

            XCTAssertFalse(model.shouldShowKeyboardMonitoringRetry)
            XCTAssertFalse(model.canRetryKeyboardMonitoring)
            XCTAssertFalse(model.shortcutMonitor.isMonitoring)
            XCTAssertEqual(model.shortcutMonitorActivationEpoch, 0)
        }
        XCTAssertEqual(preview.eventMonitoringStatus, "Not queried in preview")
        XCTAssertEqual(testModel.eventMonitoringStatus, "Inactive")
    }

    func testReplacementAndInsertionCallbacksRouteDifferentEditIntents() {
        let monitor = TestShortcutMonitor()
        let selection = TestSelectionAccess()
        let model = makeModel(monitor: monitor, selectionAccess: selection)

        monitor.fireReplacementShortcut()

        XCTAssertEqual(model.engine.state, .ready)
        XCTAssertEqual(selection.captureIntents, [.replaceSelection])

        model.dismiss()
        monitor.fireInsertionShortcut()

        XCTAssertEqual(model.engine.state, .ready)
        XCTAssertEqual(selection.captureIntents, [.replaceSelection, .insertAtCaret])
        XCTAssertEqual(model.pillModel.phase, .input)
    }

    func testInsertionShortcutConflictsWithReplacementAndPresetBindings() {
        let shortcut = InvocationConfiguration.defaultInsertAtCaretShortcut
        let configuration = InvocationConfiguration(doubleControlEnabled: false, shortcut: shortcut)
        XCTAssertNoThrow(try ShortcutMonitor.validateBindings(configuration: configuration, presets: []))

        let preset = Preset(id: "collision", name: "Collision", instruction: "Use a different tone", shortcut: shortcut)
        XCTAssertNoThrow(try ShortcutMonitor.validateBindings(configuration: .init(), presets: [preset]))

        let malformed = InvocationConfiguration(doubleControlEnabled: false, shortcut: ShortcutBinding(keyCode: 12))
        XCTAssertThrowsError(try ShortcutMonitor.validateBindings(configuration: malformed, presets: []))

        let duplicatePreset = Preset(
            id: "duplicate",
            name: "Duplicate",
            instruction: "Use a different tone",
            shortcut: ShortcutBinding(keyCode: 0, command: true)
        )
        let duplicateConfiguration = InvocationConfiguration(
            doubleControlEnabled: false,
            shortcut: ShortcutBinding(keyCode: 0, command: true)
        )
        XCTAssertThrowsError(try ShortcutMonitor.validateBindings(configuration: duplicateConfiguration, presets: [duplicatePreset]))

        let distinctConfiguration = InvocationConfiguration(
            doubleControlEnabled: false,
            shortcut: ShortcutBinding(keyCode: 0, command: true)
        )
        let distinctPreset = Preset(
            id: "distinct", name: "Distinct", instruction: "Use a different tone",
            shortcut: ShortcutBinding(keyCode: 12, option: true)
        )
        XCTAssertNoThrow(try ShortcutMonitor.validateBindings(configuration: distinctConfiguration, presets: [distinctPreset]))
    }

    private func makeModel(
        monitor: TestShortcutMonitor,
        textProvider: any TextProvider = EmptyTextProvider(),
        selectionAccess: TestSelectionAccess? = nil
    ) -> AppModel {
        let engine = TransformationEngine(
            selectionAccess: selectionAccess ?? TestSelectionAccess(),
            textProvider: textProvider
        )
        let provider = ProviderConfiguration(
            id: "test-provider",
            name: "Test provider",
            kind: .compatible,
            endpoint: URL(string: "https://provider.example.test/v1")!,
            model: "test-model",
            requiresCredential: false
        )
        return AppModel(
            testEngine: engine,
            configuration: AppConfiguration(providers: [provider], selectedProviderID: provider.id),
            shortcutMonitoring: monitor
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for shortcut monitor recovery", file: file, line: line)
    }
}

@MainActor
private final class TestShortcutMonitor: ShortcutMonitoring {
    private(set) var isMonitoring = false
    private(set) var startCount = 0
    private var startFailures: [ShortcutMonitorError]
    private var onInvoke: (@MainActor (String?) -> Void)?
    private var onInsertAtCaret: (@MainActor () -> Void)?

    init(startFailures: [ShortcutMonitorError] = []) {
        self.startFailures = startFailures
    }

    func start(
        configuration: InvocationConfiguration,
        presets: [Preset],
        onInvoke: @escaping @MainActor (String?) -> Void,
        onInsertAtCaret: @escaping @MainActor () -> Void
    ) throws {
        startCount += 1
        if !startFailures.isEmpty { throw startFailures.removeFirst() }
        isMonitoring = true
        self.onInvoke = onInvoke
        self.onInsertAtCaret = onInsertAtCaret
    }

    func stop() {
        isMonitoring = false
        onInvoke = nil
        onInsertAtCaret = nil
    }

    func fireReplacementShortcut() {
        onInvoke?(nil)
    }

    func fireInsertionShortcut() {
        onInsertAtCaret?()
    }
}

@MainActor
private final class TestSelectionAccess: SelectionAccess {
    private let holdUndo: Bool
    private var undoContinuation: CheckedContinuation<Void, Never>?
    private let snapshot = SelectionSnapshot(
        applicationID: "test.application",
        processID: 1,
        role: "textField",
        text: "original text",
        range: TextRange(location: 0, length: "original text".utf16.count)
    )

    init(holdUndo: Bool = false) {
        self.holdUndo = holdUndo
    }

    private(set) var captureIntents: [SelectionEditIntent] = []

    func capture() throws -> SelectionSnapshot { try capture(intent: .replaceSelection) }

    func capture(intent: SelectionEditIntent) throws -> SelectionSnapshot {
        captureIntents.append(intent)
        guard intent == .insertAtCaret else { return snapshot }
        return SelectionSnapshot(
            applicationID: "test.application",
            processID: 1,
            role: "textField",
            text: "",
            range: TextRange(location: 0, length: 0),
            intent: .insertAtCaret
        )
    }

    func validate(_ target: SelectionSnapshot) throws {}

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {
        guard holdUndo else { return }
        await withCheckedContinuation { undoContinuation = $0 }
    }

    func discard(_ target: SelectionSnapshot) {}

    func finishUndo() {
        let continuation = undoContinuation
        undoContinuation = nil
        continuation?.resume()
    }
}

private struct EmptyTextProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class HoldingTextProvider: TextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    var hasPendingStream: Bool { lock.withLock { continuation != nil } }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func finish(with text: String) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.yield(text)
        continuation?.finish()
    }
}
#endif
