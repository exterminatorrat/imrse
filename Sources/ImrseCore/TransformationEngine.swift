import Foundation

public enum TransformationState: Equatable, Sendable {
    case idle
    case ready
    case generating
    case replacing
    case undoing
    case succeeded(unchanged: Bool)
    case failed(ImrseError)
}

/// Session-only recovery result. Contains no captured source, target, or provider data.
/// This is not proof that an editor write succeeded and grants no paste authority.
public struct RetainedGeneratedOutput: Equatable, Sendable {
    public let id: UUID
    public let result: String
}

@MainActor
public final class TransformationEngine {
    public static let maximumSelectionUTF8Bytes = 1_048_576
    public static let maximumInstructionUTF8Bytes = 65_536
    public static let maximumOutputUTF8Bytes = 1_048_576

    public private(set) var state = TransformationState.idle
    public private(set) var diagnostics = DiagnosticMetadata()
    public private(set) var responseMetadata: ResponseMetadata?
    /// Available only after automatic application failed. Read/export never writes clipboard.
    public var retainedGeneratedOutput: RetainedGeneratedOutput? {
        expireRetainedOutputIfNeeded()
        guard case .failed = state else { return nil }
        return storedGeneratedOutput
    }
    public var onChange: (@MainActor (TransformationState) -> Void)?
    public var onPrepareReplacement: (@MainActor () -> Void)?
    public var canUndo: Bool {
        undoReceipt != nil && state != .generating && state != .replacing && state != .undoing
    }

    private let selectionAccess: any SelectionAccess
    private let textProvider: any TextProvider
    private var target: SelectionSnapshot?
    private var sourceDeadline: ContinuousClock.Instant?
    private var sourceExpiryTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var generationTask: Task<Void, Never>?
    private var undoReceipt: ReplacementReceipt?
    private var pendingResponseMetadata: ResponseMetadata?
    private var storedGeneratedOutput: RetainedGeneratedOutput?
    private var retainedOutputDeadline: ContinuousClock.Instant?
    private var retainedOutputExpiryTask: Task<Void, Never>?
    private let retainedOutputLifetime: Duration
    private let now: @MainActor () -> ContinuousClock.Instant

    public init(selectionAccess: any SelectionAccess, textProvider: any TextProvider) {
        self.selectionAccess = selectionAccess
        self.textProvider = textProvider
        retainedOutputLifetime = .seconds(180)
        now = { ContinuousClock.now }
    }

    // Internal timing seam; production callers cannot disable retention bounds.
    init(selectionAccess: any SelectionAccess, textProvider: any TextProvider,
         retainedOutputLifetime: Duration,
         now: @escaping @MainActor () -> ContinuousClock.Instant) {
        self.selectionAccess = selectionAccess
        self.textProvider = textProvider
        self.retainedOutputLifetime = retainedOutputLifetime
        self.now = now
    }

    /// Future explicit Copy Result boundary. A stale UI result ID cannot export a newer result.
    /// No clipboard operation, automatic retry, target reactivation, or success claim occurs.
    public func resultForExplicitCopy(outputID: UUID) -> String? {
        guard let output = retainedGeneratedOutput, output.id == outputID else { return nil }
        return output.result
    }

    public func invoke() {
        invoke(intent: .replaceSelection)
    }

    public func invoke(intent: SelectionEditIntent) {
        if state == .generating {
            cancel()
            return
        }
        guard state == .idle else { return }
        clearRetainedOutput()
        responseMetadata = nil
        pendingResponseMetadata = nil
        diagnostics = DiagnosticMetadata()

        let snapshot: SelectionSnapshot
        do {
            snapshot = try selectionAccess.capture(intent: intent)
        } catch {
            let selectionFailureReason = selectionAccess.lastFailureReason
            fail(Self.captureFailure(error), selectionFailureReason: selectionFailureReason)
            return
        }

        diagnostics.applicationID = Self.safeMetadata(snapshot.applicationID)
        diagnostics.role = Self.safeMetadata(snapshot.role)
        diagnostics.selectionLength = snapshot.isSecure ? nil : snapshot.text.utf16.count
        diagnostics.targetValid = nil
        diagnostics.strategy = nil

        guard snapshot.intent == intent else {
            selectionAccess.discard(snapshot)
            fail(.insertionUnavailable)
            return
        }

        if let error = Self.snapshotFailure(snapshot) {
            selectionAccess.discard(snapshot)
            fail(error)
            return
        }

        target = snapshot
        sourceDeadline = now().advanced(by: .seconds(180))
        let sourceID = snapshot.id
        sourceExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            guard let self, self.state == .ready, self.target?.id == sourceID else { return }
            self.fail(.timeout)
        }
        diagnostics.error = nil
        diagnostics.generation = "idle"
        diagnostics.replacement = "idle"
        transition(to: .ready)
    }

    public func submit(
        instruction: String,
        provider: ProviderConfiguration,
        localOnly: Bool = false,
        fallbackProvider: ProviderConfiguration? = nil
    ) {
        guard state == .ready, let target else { return }
        guard let sourceDeadline, now() < sourceDeadline else { fail(.timeout); return }
        clearRetainedOutput()
        responseMetadata = nil
        pendingResponseMetadata = nil
        if target.intent == .insertAtCaret,
           instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail(.missingInstruction)
            return
        }
        guard instruction.utf8.count <= Self.maximumInstructionUTF8Bytes else {
            fail(.instructionTooLarge)
            return
        }
        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(.missingModel)
            return
        }

        let operationID = UUID()
        let request = TransformationRequest(
            text: target.text,
            instruction: instruction,
            provider: provider,
            localOnly: localOnly,
            fallbackProvider: fallbackProvider,
            reportProvider: { [weak self] reportedProvider in
                guard let self, self.activeOperationID == operationID, self.state == .generating else { return }
                if reportedProvider.id != provider.id {
                    self.responseMetadata = nil
                    self.pendingResponseMetadata = nil
                }
                self.diagnostics.providerName = Self.safeMetadata(reportedProvider.name)
                self.diagnostics.model = Self.safeMetadata(reportedProvider.model)
                self.onChange?(self.state)
            },
            reportResponseMetadata: { [weak self] metadata in
                guard let self, self.activeOperationID == operationID,
                      self.state == .generating, !Task.isCancelled
                else { return }
                let hasMetadata = metadata.detectedModel != nil || metadata.inputTokens != nil
                    || metadata.outputTokens != nil || metadata.totalTokens != nil || metadata.costUSD != nil
                self.pendingResponseMetadata = hasMetadata ? metadata : nil
            }
        )
        activeOperationID = operationID
        diagnostics.providerName = Self.safeMetadata(provider.name)
        diagnostics.model = Self.safeMetadata(provider.model)
        diagnostics.error = nil
        diagnostics.generation = "running"
        diagnostics.replacement = "idle"
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.generate(request, target: target, operationID: operationID)
        }
        transition(to: .generating)
    }

    public func rejectSubmission(_ error: ImrseError) {
        guard state == .ready else { return }
        fail(error)
    }

    public func cancel() {
        clearRetainedOutput()
        guard state == .ready || state == .generating else { return }
        invalidateGeneration(cancelTask: true)
        responseMetadata = nil
        pendingResponseMetadata = nil
        discardTarget()
        diagnostics.error = .cancelled
        diagnostics.generation = "cancelled"
        diagnostics.replacement = "idle"
        transition(to: .failed(.cancelled))
    }

    public func dismiss() {
        guard state != .replacing, state != .undoing else { return }
        clearRetainedOutput()
        if state == .generating { invalidateGeneration(cancelTask: true) }
        responseMetadata = nil
        pendingResponseMetadata = nil
        discardTarget()
        diagnostics.targetValid = nil
        transition(to: .idle)
    }

    public func undo() async {
        guard state != .generating, state != .replacing, state != .undoing else { return }
        clearRetainedOutput()
        guard let receipt = undoReceipt else {
            fail(.undoUnavailable)
            return
        }

        discardTarget()
        if selectionAccess.isClipboardUndoDisabled(receipt) {
            diagnostics.error = .clipboardUndoDisabled
            diagnostics.selectionFailureReason = nil
            diagnostics.writeAttempt = nil
            diagnostics.replacementOutcome = nil
            diagnostics.targetValid = nil
            diagnostics.generation = "idle"
            diagnostics.replacement = "failed"
            // Configuration refusal is proven non-writing. Preserve this receipt;
            // re-enabling only permits a future attempt, not bypassing validation.
            transition(to: .failed(.clipboardUndoDisabled))
            return
        }
        undoReceipt = nil
        diagnostics.error = nil
        diagnostics.replacementOutcome = nil
        diagnostics.writeAttempt = nil
        diagnostics.replacement = "undoing"
        transition(to: .undoing)
        do {
            try await selectionAccess.undo(receipt)
            diagnostics.writeAttempt = selectionAccess.lastWriteAttempt
            selectionAccess.discard(receipt.target)
            diagnostics.strategy = receipt.strategy
            diagnostics.error = nil
            diagnostics.selectionFailureReason = nil
            diagnostics.generation = "idle"
            diagnostics.replacement = "undone"
            transition(to: .succeeded(unchanged: false))
        } catch {
            diagnostics.writeAttempt = selectionAccess.lastWriteAttempt
            let selectionFailureReason = selectionAccess.lastFailureReason
            selectionAccess.discard(receipt.target)
            let failure = Self.undoFailure(error)
            diagnostics.error = failure
            diagnostics.selectionFailureReason = selectionFailureReason
            diagnostics.targetValid = false
            diagnostics.replacement = "failed"
            transition(to: .failed(failure))
        }
    }

    private func generate(
        _ request: TransformationRequest,
        target: SelectionSnapshot,
        operationID: UUID
    ) async {
        do {
            guard isGenerating(operationID) else { return }
            guard let sourceDeadline, now() < sourceDeadline else { throw ImrseError.timeout }
            let stream = try await textProvider.stream(request)
            guard isGenerating(operationID) else { return }

            var fragments: [String] = []
            var outputLength = 0
            for try await fragment in stream {
                guard isGenerating(operationID) else { return }
                guard !fragment.isEmpty else { continue }
                let fragmentLength = fragment.utf8.count
                guard fragmentLength <= Self.maximumOutputUTF8Bytes - outputLength else {
                    throw ImrseError.outputTooLarge
                }
                outputLength += fragmentLength
                fragments.append(fragment)
            }

            guard isGenerating(operationID) else { return }
            let output = fragments.joined()
            try Self.validateOutput(output, utf8Length: outputLength)
            responseMetadata = pendingResponseMetadata
            pendingResponseMetadata = nil
            if output.utf16.elementsEqual(target.text.utf16) {
                finish(operationID, unchanged: true)
                return
            }

            onPrepareReplacement?()
            guard isGenerating(operationID) else { return }
            do {
                try await selectionAccess.prepareForReplacement(target)
                guard isGenerating(operationID) else { return }
                try selectionAccess.validate(target)
                diagnostics.targetValid = true
            } catch {
                guard isGenerating(operationID) else { return }
                let selectionFailureReason = selectionAccess.lastFailureReason
                diagnostics.targetValid = false
                finish(
                    operationID,
                    failure: Self.validationFailure(error),
                    generatedOutput: output,
                    selectionFailureReason: selectionFailureReason
                )
                return
            }
            guard isGenerating(operationID) else { return }

            diagnostics.replacement = "running"
            transition(to: .replacing)
            let outcome = await selectionAccess.replace(target, with: output)
            guard activeOperationID == operationID, state == .replacing else { return }
            diagnostics.writeAttempt = selectionAccess.lastWriteAttempt
            diagnostics.replacementOutcome = outcome.status
            switch outcome {
            case .applied(let receipt):
                guard receipt.target == target,
                      receipt.target.text.utf16.elementsEqual(target.text.utf16),
                      receipt.replacement.utf16.elementsEqual(output.utf16)
                else {
                    diagnostics.replacementOutcome = .unconfirmed
                    diagnostics.targetValid = false
                    finish(
                        operationID,
                        failure: .replacementFailed,
                        generatedOutput: output,
                        replacementFailed: true,
                        invalidatesPriorUndo: true
                    )
                    return
                }
                if let previousReceipt = undoReceipt {
                    selectionAccess.discard(previousReceipt.target)
                }
                undoReceipt = receipt
                self.target = nil
                activeOperationID = nil
                generationTask = nil
                diagnostics.error = nil
                diagnostics.selectionFailureReason = nil
                diagnostics.strategy = receipt.strategy
                diagnostics.generation = "complete"
                diagnostics.replacement = "replaced"
                transition(to: .succeeded(unchanged: false))
            case .notWritten(let error, let invalidatesPriorUndo):
                let selectionFailureReason = selectionAccess.lastFailureReason
                let failure = Self.replacementFailure(error)
                if failure == .targetLost || failure == .staleSelection { diagnostics.targetValid = false }
                finish(
                    operationID,
                    failure: failure,
                    generatedOutput: output,
                    replacementFailed: true,
                    selectionFailureReason: selectionFailureReason,
                    invalidatesPriorUndo: invalidatesPriorUndo
                )
            case .unconfirmed(let error):
                let selectionFailureReason = selectionAccess.lastFailureReason
                let failure = Self.replacementFailure(error)
                diagnostics.targetValid = false
                finish(
                    operationID,
                    failure: failure == .staleSelection ? .replacementFailed : failure,
                    generatedOutput: output,
                    replacementFailed: true,
                    selectionFailureReason: selectionFailureReason,
                    invalidatesPriorUndo: true
                )
            }
        } catch {
            guard activeOperationID == operationID else { return }
            finish(operationID, failure: Self.providerFailure(error))
        }
    }

    private func finish(_ operationID: UUID, unchanged: Bool) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        generationTask = nil
        discardTarget()
        diagnostics.error = nil
        diagnostics.selectionFailureReason = nil
        diagnostics.generation = "complete"
        diagnostics.replacement = unchanged ? "unchanged" : "replaced"
        transition(to: .succeeded(unchanged: unchanged))
    }

    private func finish(
        _ operationID: UUID,
        failure: ImrseError,
        generatedOutput: String? = nil,
        replacementFailed: Bool = false,
        selectionFailureReason: SelectionFailureReason? = nil,
        invalidatesPriorUndo: Bool = false
    ) {
        guard activeOperationID == operationID else { return }
        clearRetainedOutput()
        if failure != .cancelled, let generatedOutput,
           generatedOutput.utf8.count <= Self.maximumOutputUTF8Bytes {
            retainGeneratedOutput(generatedOutput)
        }
        invalidateGeneration(cancelTask: false)
        pendingResponseMetadata = nil
        if invalidatesPriorUndo {
            if let previousReceipt = undoReceipt {
                selectionAccess.discard(previousReceipt.target)
            }
            undoReceipt = nil
        }
        discardTarget()
        diagnostics.error = failure
        diagnostics.selectionFailureReason = selectionFailureReason
        diagnostics.generation = failure == .cancelled ? "cancelled" : "failed"
        diagnostics.replacement = replacementFailed ? "failed" : "idle"
        transition(to: .failed(failure))
    }

    private func fail(_ failure: ImrseError, selectionFailureReason: SelectionFailureReason? = nil) {
        clearRetainedOutput()
        responseMetadata = nil
        pendingResponseMetadata = nil
        discardTarget()
        diagnostics.error = failure
        diagnostics.selectionFailureReason = selectionFailureReason
        diagnostics.generation = failure == .cancelled ? "cancelled" : "idle"
        diagnostics.replacement = "idle"
        transition(to: .failed(failure))
    }

    private func retainGeneratedOutput(_ result: String) {
        let output = RetainedGeneratedOutput(id: UUID(), result: result)
        storedGeneratedOutput = output
        retainedOutputDeadline = now().advanced(by: retainedOutputLifetime)
        let outputID = output.id
        retainedOutputExpiryTask = Task { [weak self, retainedOutputLifetime] in
            do { try await Task.sleep(for: retainedOutputLifetime) } catch { return }
            guard let self, self.storedGeneratedOutput?.id == outputID else { return }
            self.clearRetainedOutput()
            self.onChange?(self.state)
        }
    }

    private func expireRetainedOutputIfNeeded() {
        guard let deadline = retainedOutputDeadline, now() >= deadline else { return }
        clearRetainedOutput()
    }

    private func clearRetainedOutput() {
        retainedOutputExpiryTask?.cancel()
        retainedOutputExpiryTask = nil
        retainedOutputDeadline = nil
        storedGeneratedOutput = nil
    }

    private func invalidateGeneration(cancelTask: Bool) {
        let task = generationTask
        activeOperationID = nil
        generationTask = nil
        if cancelTask { task?.cancel() }
    }

    private func discardTarget() {
        sourceExpiryTask?.cancel()
        sourceExpiryTask = nil
        sourceDeadline = nil
        guard let target else { return }
        self.target = nil
        selectionAccess.discard(target)
    }

    private func isGenerating(_ operationID: UUID) -> Bool {
        activeOperationID == operationID && state == .generating && !Task.isCancelled
    }

    private func transition(to newState: TransformationState) {
        guard state != newState else { return }
        state = newState
        onChange?(newState)
    }

    private static func snapshotFailure(_ snapshot: SelectionSnapshot) -> ImrseError? {
        if snapshot.isSecure { return .secureInput }
        switch snapshot.intent {
        case .replaceSelection:
            let length = snapshot.text.utf16.count
            guard length > 0 else { return .noSelection }
            guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noSelection }
            guard snapshot.text.utf8.count <= maximumSelectionUTF8Bytes else { return .selectionTooLarge }
            if let range = snapshot.range {
                guard range.location >= 0, range.length == length else { return .noSelection }
                let (_, overflow) = range.location.addingReportingOverflow(range.length)
                guard !overflow else { return .noSelection }
            }
        case .insertAtCaret:
            guard snapshot.text.isEmpty,
                  let range = snapshot.range,
                  range.location >= 0,
                  range.length == 0
            else { return .insertionUnavailable }
        }
        return nil
    }

    private static func validateOutput(_ output: String, utf8Length: Int) throws {
        guard utf8Length <= maximumOutputUTF8Bytes else { throw ImrseError.outputTooLarge }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImrseError.emptyOutput }
        let invalidControl = output.unicodeScalars.contains { scalar in
            let value = scalar.value
            if value == 9 || value == 10 || value == 13 { return false }
            return value < 32 || (127...159).contains(value)
        }
        guard !invalidControl else { throw ImrseError.malformedResponse }
    }

    private static func safeMetadata(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128))
    }

    private static func captureFailure(_ error: any Error) -> ImrseError {
        (error as? ImrseError) ?? .noSelection
    }

    private static func validationFailure(_ error: any Error) -> ImrseError {
        if error is CancellationError { return .cancelled }
        return (error as? ImrseError) ?? .targetLost
    }

    private static func replacementFailure(_ error: any Error) -> ImrseError {
        guard let error = error as? ImrseError else { return .replacementFailed }
        return switch error {
        case .targetLost, .staleSelection, .clipboardFailed, .clipboardPending, .permissionRequired, .cancelled, .unsupportedEditor: error
        default: .replacementFailed
        }
    }

    private static func undoFailure(_ error: any Error) -> ImrseError {
        guard let error = error as? ImrseError else { return .undoUnavailable }
        return switch error {
        case .clipboardPending: .clipboardPending
        case .staleSelection, .targetLost, .replacementFailed, .clipboardFailed: .undoUnavailable
        default: error
        }
    }

    private static func providerFailure(_ error: any Error) -> ImrseError {
        if let error = error as? ImrseError { return error }
        if error is CancellationError { return .cancelled }
        guard let error = error as? URLError else { return .server }
        return switch error.code {
        case .timedOut: .timeout
        case .cancelled: .cancelled
        case .userAuthenticationRequired, .userCancelledAuthentication: .authentication
        default: .network
        }
    }
}
