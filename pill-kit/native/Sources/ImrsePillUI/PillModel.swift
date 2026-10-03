import Foundation
import Combine
import ImrsePillCore

public struct PillSubmission: Sendable {
    public let id: UUID
    /// nil means that the host must use default.md; this UI does not read configuration files.
    public let instruction: String?
    public let presetID: String?
}

public struct PillPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let instruction: String
    public let motion: PillMotion
    public init(id: String, name: String, instruction: String, motion: PillMotion = .quick) {
        self.id = id; self.name = name; self.instruction = instruction; self.motion = motion
    }
}

@MainActor
public final class PillModel: ObservableObject {
    private let lifecycleChangesSubject = PassthroughSubject<PillLifecycle, Never>()
    @Published public private(set) var lifecycle = PillLifecycle() {
        didSet { lifecycleChangesSubject.send(lifecycle) }
    }
    @Published public var instruction = ""
    @Published public var presets: [PillPreset] = []
    @Published public var motion: PillMotion = .quick
    @Published public private(set) var startedAt = Date()
    @Published public private(set) var canUndo = false
    @Published public private(set) var selectedPresetID: String?
    @Published public private(set) var inputIsFocused = false
    public var phase: PillPhase { lifecycle.phase }
    public var onSubmit: (PillSubmission) -> Void
    public var onCancel: (UUID) -> Void
    public var onUndo: (() -> Void)?
    public var lifecycleChanges: AnyPublisher<PillLifecycle, Never> {
        lifecycleChangesSubject.eraseToAnyPublisher()
    }
    /// Leave nil for persistent success feedback (e.g. accessibility needs).
    public var successDismissDelay: TimeInterval? = 1.8
    private var dismissTask: Task<Void, Never>?

    public init(onSubmit: @escaping (PillSubmission) -> Void, onCancel: @escaping (UUID) -> Void = { _ in }, onUndo: (() -> Void)? = nil) {
        self.onSubmit = onSubmit; self.onCancel = onCancel; self.onUndo = onUndo
    }

    /// Call only AFTER the host has captured and validated its original AX target.
    public func present() {
        guard phase.activeRequestID == nil, phase != .input else { return }
        dismissTask?.cancel()
        instruction = ""
        selectedPresetID = nil
        canUndo = false
        inputIsFocused = false
        lifecycle.send(.invoke)
    }

    public func applyPreset(at index: Int) {
        guard phase == .input, presets.indices.contains(index) else { return }
        selectedPresetID = presets[index].id
        instruction = presets[index].instruction
        motion = presets[index].motion
    }

    public func setInputFocused(_ focused: Bool) {
        inputIsFocused = focused
    }

    public func showCaptureFailure(message: String) {
        guard phase.activeRequestID == nil else { return }
        dismissTask?.cancel()
        dismissTask = nil
        selectedPresetID = nil
        canUndo = false
        inputIsFocused = false
        lifecycle.send(.captureFailed(message))
    }

    public func submit() {
        guard phase == .input else { return }
        let id = UUID()
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        startedAt = Date()
        inputIsFocused = false
        lifecycle.send(.submit(id))
        onSubmit(PillSubmission(id: id, instruction: text.isEmpty ? nil : text, presetID: selectedPresetID))
    }

    /// Generation is complete; the original target must still be revalidated by the host.
    public func generated(_ id: UUID) { lifecycle.send(.generated(id)) }

    /// Call only after the host has confirmed the selected text was replaced.
    public func applied(_ id: UUID, undoAvailable: Bool) {
        guard phase == .applying(id) else { return }
        canUndo = undoAvailable && onUndo != nil
        lifecycle.send(.applied(id))
        dismissTask?.cancel()
        guard let delay = successDismissDelay, delay.isFinite, delay > 0 else { return }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(delay, 60) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, let self, self.phase == .success(id) else { return }
            self.dismiss()
        }
    }

    /// Supply a short user-safe message, never a raw provider response or selected text.
    public func failed(_ id: UUID, message: String) {
        inputIsFocused = false
        lifecycle.send(.failed(id, message))
    }

    public func dismiss() {
        let id = phase.activeRequestID
        dismissTask?.cancel(); dismissTask = nil
        inputIsFocused = false
        lifecycle.send(.dismiss)
        if let id { onCancel(id) }
    }

    deinit { dismissTask?.cancel() }

    public func undo() {
        guard canUndo else { return }
        onUndo?()
        // The host must verify its own undo target and expose any undo error separately.
        dismiss()
    }
}
