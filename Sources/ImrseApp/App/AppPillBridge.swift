#if os(macOS)
import AppKit
import Combine
import ImrseCore
import ImrsePillUI
import ImrseServices

@MainActor
final class AppPillBridge {
    let engine: TransformationEngine
    let pill: PillModel

    private var configuration: AppConfiguration
    private var defaultInstruction: String
    private var presets: [Preset]
    private let screenAfterCapture: () -> NSScreen?
    private let fallbackScreen: () -> NSScreen?
    private var captureInProgress = false
    private var captureFallbackScreen: NSScreen?
    private var activeSubmissionID: UUID?
    private var pillLifecycleSubscription: AnyCancellable?

    #if DEBUG
    var isPreviewMode = false
    #endif
    var onPresent: (@MainActor (NSScreen?) -> Void)?
    var onStateChange: (@MainActor (TransformationState) -> Void)?
    var onUndo: (@MainActor () -> Void)?

    init(
        engine: TransformationEngine,
        pill: PillModel,
        configuration: AppConfiguration,
        defaultInstruction: String,
        presets: [Preset],
        screenAfterCapture: @escaping () -> NSScreen?,
        fallbackScreen: @escaping () -> NSScreen?
    ) {
        self.engine = engine
        self.pill = pill
        self.configuration = configuration
        self.defaultInstruction = defaultInstruction
        self.presets = presets
        self.screenAfterCapture = screenAfterCapture
        self.fallbackScreen = fallbackScreen
        updatePresentationSettings()

        pill.onSubmit = { [weak self] submission in self?.submit(submission) }
        pill.onCancel = { [weak self] id in self?.cancel(id) }
        pill.onUndo = { [weak self] in self?.onUndo?() }
        engine.onChange = { [weak self] state in self?.handle(state) }
        pillLifecycleSubscription = pill.$lifecycle.sink { [weak self] lifecycle in
            guard lifecycle.phase == .hidden, self?.engine.state == .ready else { return }
            self?.engine.dismiss()
        }
    }

    func update(configuration: AppConfiguration, defaultInstruction: String, presets: [Preset]) {
        self.configuration = configuration
        self.defaultInstruction = defaultInstruction
        self.presets = presets
        updatePresentationSettings()
    }

    func invoke(presetID: String? = nil) {
        guard acceptsActions else { return }
        if pill.phase == .input { return }
        if engine.state == .generating {
            pill.dismiss()
            return
        }
        guard engine.state != .replacing, engine.state != .undoing else { return }
        if let presetID, !presets.contains(where: { $0.id == presetID }) {
            pill.showCaptureFailure(message: ImrseError.invalidPreset.message)
            onPresent?(fallbackScreen())
            return
        }

        captureFallbackScreen = fallbackScreen()
        captureInProgress = true
        if engine.state != .idle { engine.dismiss() }
        engine.invoke()
        captureInProgress = false

        guard engine.state == .ready else {
            captureFallbackScreen = nil
            return
        }

        updatePresentationSettings()
        pill.present()
        onPresent?(screenAfterCapture() ?? captureFallbackScreen)
        captureFallbackScreen = nil

        if let presetID, let index = pill.presets.firstIndex(where: { $0.id == presetID }) {
            pill.applyPreset(at: index)
            pill.submit()
        }
    }

    @discardableResult
    func selectPreset(at index: Int) -> Bool {
        guard acceptsActions,
              pill.phase == .input,
              pill.inputIsFocused,
              pill.presets.indices.contains(index)
        else { return false }
        pill.applyPreset(at: index)
        return true
    }

    func dismiss() {
        switch engine.state {
        case .ready:
            engine.dismiss()
        default:
            break
        }
        pill.dismiss()
    }

    private func submit(_ submission: PillSubmission) {
        guard acceptsActions, pill.phase == .processing(submission.id) else { return }
        activeSubmissionID = submission.id
        let preset: Preset?
        if let presetID = submission.presetID {
            guard let configuredPreset = presets.first(where: { $0.id == presetID }) else {
                engine.rejectSubmission(.invalidPreset)
                return
            }
            preset = configuredPreset
        } else {
            preset = nil
        }

        do {
            let route = try ProviderRouter(configuration: configuration).resolve(
                preset: preset,
                localOnly: preset?.localOnly ?? false
            )
            let instruction = submission.instruction ?? defaultInstruction
            engine.submit(
                instruction: instruction,
                provider: route.primary,
                localOnly: route.localOnly,
                fallbackProvider: route.fallback
            )
        } catch {
            engine.rejectSubmission((error as? ImrseError) ?? .invalidConfiguration)
        }
    }

    private func cancel(_ id: UUID) {
        guard activeSubmissionID == id, engine.state == .generating else { return }
        engine.cancel()
    }

    private func handle(_ state: TransformationState) {
        switch state {
        case .replacing:
            if let activeSubmissionID { pill.generated(activeSubmissionID) }
        case .succeeded(let unchanged):
            guard let id = activeSubmissionID else { break }
            activeSubmissionID = nil
            if unchanged {
                pill.dismiss()
            } else {
                pill.applied(id, undoAvailable: engine.canUndo)
            }
        case .failed(let error):
            if let id = activeSubmissionID {
                activeSubmissionID = nil
                pill.failed(id, message: error.message)
            } else if captureInProgress {
                captureInProgress = false
                pill.showCaptureFailure(message: error.message)
                onPresent?(captureFallbackScreen)
                captureFallbackScreen = nil
            }
        default:
            break
        }
        onStateChange?(state)
    }

    private func updatePresentationSettings() {
        pill.motion = Self.pillMotion(for: configuration.motion)
        pill.presets = presets.map { preset in
            let motion = preset.motion ?? configuration.motion
            return PillPreset(
                id: preset.id,
                name: preset.name,
                instruction: preset.instruction,
                motion: Self.pillMotion(for: motion)
            )
        }
    }

    private static func pillMotion(for preference: MotionPreference) -> PillMotion {
        switch preference {
        case .instant: return .instant
        case .quick: return .quick
        case .smooth: return .smooth
        case .balanced: return .balanced
        case .slow: return .slow
        }
    }

    private var acceptsActions: Bool {
        #if DEBUG
        !isPreviewMode
        #else
        true
        #endif
    }

}
#endif
