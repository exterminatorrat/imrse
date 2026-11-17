import Foundation

/// Backend for an explicit user-supplied-text workflow. No selection, clipboard,
/// focus, replacement, persistence or Undo capability is available to this type.
@MainActor
public final class ManualPreviewSession {
    public enum State: Equatable, Sendable {
        case idle, generating, cancelling, preview, failed(ImrseError)
    }

    public struct Preview: Equatable, Sendable {
        public let id: UUID
        public let source: String
        public let result: String
        /// Equality is informational, never evidence of an editor write.
        public var unchanged: Bool { source == result }
    }

    public private(set) var state: State = .idle
    public var preview: Preview? {
        expirePreviewIfNeeded()
        return storedPreview
    }
    private var storedPreview: Preview?
    /// Cancellation is cooperative. Admission stays closed until this consumer exits.
    public var isBusy: Bool { generationTask != nil }
    public var onChange: (@MainActor (State) -> Void)?

    private let provider: any TextProvider
    private let generationTimeout: Duration
    private let previewLifetime: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private var generationDeadline: ContinuousClock.Instant?
    private var previewDeadline: ContinuousClock.Instant?
    private var generationTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var operationID: UUID?
    private var terminalState: State = .idle

    public init(provider: any TextProvider) {
        self.provider = provider
        generationTimeout = .seconds(90)
        previewLifetime = .seconds(180)
        now = { ContinuousClock.now }
    }

    // Internal timing seam; production callers cannot disable retention/deadline bounds.
    init(provider: any TextProvider, generationTimeout: Duration, previewLifetime: Duration,
         now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.provider = provider
        self.generationTimeout = generationTimeout
        self.previewLifetime = previewLifetime
        self.now = now
    }

    /// Call only following explicit user submission of source and provider choice.
    /// This does not read the pasteboard. Remote transmission policy remains the
    /// caller's responsibility; localOnly and explicit fallback are preserved.
    @discardableResult
    public func generate(source: String, instruction: String, configuration: ProviderConfiguration,
                         localOnly: Bool = false, fallbackProvider: ProviderConfiguration? = nil) -> Bool {
        guard !isBusy else { return false }
        clearPreview()
        let failure: ImrseError?
        if source.isEmpty { failure = .noSelection }
        else if source.utf8.count > TransformationEngine.maximumSelectionUTF8Bytes { failure = .selectionTooLarge }
        else if instruction.utf8.count > TransformationEngine.maximumInstructionUTF8Bytes { failure = .instructionTooLarge }
        else if configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failure = .missingModel }
        else { failure = nil }
        if let failure { transition(.failed(failure)); return false }
        let id = UUID()
        operationID = id
        generationDeadline = now().advanced(by: generationTimeout)
        let request = TransformationRequest(text: source, instruction: instruction, provider: configuration,
                                            localOnly: localOnly, fallbackProvider: fallbackProvider)
        generationTask = Task { [weak self, provider] in
            do {
                try Task.checkCancellation()
                guard self?.isCurrentBeforeDeadline(id) == true else { throw ImrseError.timeout }
                let stream = try await provider.stream(request)
                var output = ""
                var outputBytes = 0
                for try await fragment in stream {
                    try Task.checkCancellation()
                    guard self?.isCurrentBeforeDeadline(id) == true else { throw ImrseError.timeout }
                    guard fragment.utf8.count <= TransformationEngine.maximumOutputUTF8Bytes - outputBytes else {
                        throw ImrseError.outputTooLarge
                    }
                    outputBytes += fragment.utf8.count
                    output.append(fragment)
                }
                try Task.checkCancellation()
                guard !output.isEmpty else { throw ImrseError.emptyOutput }
                self?.finish(id: id, source: request.text, result: .success(output))
            } catch {
                let failure = error as? ImrseError ?? (error is CancellationError ? .cancelled : .providerUnavailable)
                self?.finish(id: id, source: request.text, result: .failure(failure))
            }
        }
        expiryTask = Task { [weak self, generationTimeout] in
            do { try await Task.sleep(for: generationTimeout) } catch { return }
            guard let self, self.operationID == id else { return }
            self.stop(then: .failed(.timeout))
        }
        transition(.generating)
        return true
    }

    public func cancel() { stop(then: .failed(.cancelled)) }
    public func dismiss() { stop(then: .idle) }

    /// Explicit export boundary for a future Copy Result action. Returns content
    /// only for the still-current preview. Does not write clipboard or claim copied.
    public func resultForExplicitCopy(previewID: UUID) -> String? {
        expirePreviewIfNeeded()
        guard state == .preview, let preview = storedPreview, preview.id == previewID else { return nil }
        return preview.result
    }

    private func stop(then finalState: State) {
        operationID = nil
        generationDeadline = nil
        clearPreview()
        terminalState = finalState
        if let generationTask {
            generationTask.cancel()
            transition(.cancelling)
        } else { transition(finalState) }
    }

    private func isCurrentBeforeDeadline(_ id: UUID) -> Bool {
        guard operationID == id, let deadline = generationDeadline else { return false }
        return now() < deadline
    }

    private func finish(id: UUID, source: String, result: Result<String, ImrseError>) {
        generationTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        guard operationID == id else { transition(terminalState); return }
        operationID = nil
        guard let deadline = generationDeadline, now() < deadline else {
            generationDeadline = nil
            transition(.failed(.timeout))
            return
        }
        generationDeadline = nil
        switch result {
        case .failure(let error): transition(.failed(error))
        case .success(let output):
            let item = Preview(id: UUID(), source: source, result: output)
            storedPreview = item
            previewDeadline = now().advanced(by: previewLifetime)
            let previewID = item.id
            expiryTask = Task { [weak self, previewLifetime] in
                do { try await Task.sleep(for: previewLifetime) } catch { return }
                guard let self, self.storedPreview?.id == previewID else { return }
                self.clearPreview()
                self.transition(.idle)
            }
            transition(.preview)
        }
    }

    private func clearPreview() {
        expiryTask?.cancel()
        expiryTask = nil
        storedPreview = nil
        previewDeadline = nil
    }
    private func expirePreviewIfNeeded() {
        guard let deadline = previewDeadline, now() >= deadline else { return }
        clearPreview()
        transition(.idle)
    }
    private func transition(_ next: State) { state = next; onChange?(next) }
    deinit { generationTask?.cancel(); expiryTask?.cancel() }
}
