import Foundation

public enum TransformationState: Equatable, Sendable {
    case idle
    case ready
    case generating
    case proposal(TransformationProposal)
    case replacing
    case undoing
    case succeeded(unchanged: Bool)
    case failed(ImrseError)
}

@MainActor
public final class TransformationEngine {
    public static let maximumSelectionUTF8Bytes = 1_048_576
    public static let maximumInstructionUTF8Bytes = 65_536
    public static let maximumOutputUTF8Bytes = 1_048_576

    public private(set) var state = TransformationState.idle
    public private(set) var diagnostics = DiagnosticMetadata()
    public private(set) var responseMetadata: ResponseMetadata?
    public var onChange: (@MainActor (TransformationState) -> Void)?
    public var canUndo: Bool {
        undoReceipt != nil && !isProposalPending && state != .generating && state != .replacing && state != .undoing
    }

    private let selectionAccess: any SelectionAccess
    private let textProvider: any TextProvider
    private var target: SelectionSnapshot?
    private var activeOperationID: UUID?
    private var generationTask: Task<Void, Never>?
    private var undoReceipt: ReplacementReceipt?
    private var pendingResponseMetadata: ResponseMetadata?

    private var isProposalPending: Bool {
        if case .proposal = state { return true }
        return false
    }

    public init(selectionAccess: any SelectionAccess, textProvider: any TextProvider) {
        self.selectionAccess = selectionAccess
        self.textProvider = textProvider
    }

    public func invoke() {
        if state == .generating {
            cancel()
            return
        }
        if isProposalPending { dismiss() }
        guard state == .idle else { return }
        responseMetadata = nil
        pendingResponseMetadata = nil
        diagnostics = DiagnosticMetadata()

        let snapshot: SelectionSnapshot
        do {
            snapshot = try selectionAccess.capture()
        } catch {
            fail(Self.captureFailure(error))
            return
        }

        diagnostics.applicationID = Self.safeMetadata(snapshot.applicationID)
        diagnostics.role = Self.safeMetadata(snapshot.role)
        diagnostics.selectionLength = snapshot.isSecure ? nil : snapshot.text.utf16.count
        diagnostics.targetValid = nil
        diagnostics.strategy = nil

        if let error = Self.snapshotFailure(snapshot) {
            selectionAccess.discard(snapshot)
            fail(error)
            return
        }

        target = snapshot
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
        startGeneration(
            instruction: instruction,
            provider: provider,
            localOnly: localOnly,
            fallbackProvider: fallbackProvider,
            proposalRequestID: nil
        )
    }

    public func submitProposal(
        requestID: UUID,
        instruction: String,
        provider: ProviderConfiguration,
        localOnly: Bool = false,
        fallbackProvider: ProviderConfiguration? = nil
    ) {
        startGeneration(
            instruction: instruction,
            provider: provider,
            localOnly: localOnly,
            fallbackProvider: fallbackProvider,
            proposalRequestID: requestID
        )
    }

    private func startGeneration(
        instruction: String,
        provider: ProviderConfiguration,
        localOnly: Bool,
        fallbackProvider: ProviderConfiguration?,
        proposalRequestID: UUID?
    ) {
        guard state == .ready, let target else { return }
        responseMetadata = nil
        pendingResponseMetadata = nil
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
            await self.generate(request, target: target, operationID: operationID, proposalRequestID: proposalRequestID)
        }
        transition(to: .generating)
    }

    public func commitProposal(_ id: UUID) {
        guard case .proposal(let proposal) = state, proposal.id == id else { return }
        guard let target, target.id == proposal.targetID else {
            fail(.targetLost)
            return
        }

        let operationID = UUID()
        activeOperationID = operationID
        generationTask = nil
        diagnostics.error = nil
        diagnostics.replacement = "running"
        transition(to: .replacing)
        do {
            try selectionAccess.validate(target)
            guard activeOperationID == operationID, state == .replacing else { return }
            diagnostics.targetValid = true
        } catch {
            guard activeOperationID == operationID, state == .replacing else { return }
            diagnostics.targetValid = false
            finish(operationID, failure: Self.validationFailure(error))
            return
        }
        if proposal.text == target.text {
            finish(operationID, unchanged: true)
            return
        }
        generationTask = Task { [weak self] in
            guard let self, self.activeOperationID == operationID, self.state == .replacing else { return }
            await self.replace(proposal.text, target: target, operationID: operationID)
        }
    }

    public func discardProposal(_ id: UUID) {
        guard case .proposal(let proposal) = state, proposal.id == id else { return }
        cancel()
    }

    public func rejectSubmission(_ error: ImrseError) {
        guard state == .ready else { return }
        fail(error)
    }

    public func cancel() {
        guard state == .ready || state == .generating || isProposalPending else { return }
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
        if state == .generating { invalidateGeneration(cancelTask: true) }
        responseMetadata = nil
        pendingResponseMetadata = nil
        discardTarget()
        diagnostics.targetValid = nil
        transition(to: .idle)
    }

    public func undo() async {
        guard !isProposalPending, state != .generating, state != .replacing, state != .undoing else { return }
        guard let receipt = undoReceipt else {
            fail(.undoUnavailable)
            return
        }

        discardTarget()
        undoReceipt = nil
        diagnostics.error = nil
        diagnostics.replacement = "undoing"
        transition(to: .undoing)
        do {
            try await selectionAccess.undo(receipt)
            selectionAccess.discard(receipt.target)
            diagnostics.strategy = receipt.strategy
            diagnostics.error = nil
            diagnostics.generation = "idle"
            diagnostics.replacement = "undone"
            transition(to: .succeeded(unchanged: false))
        } catch {
            selectionAccess.discard(receipt.target)
            let failure = Self.undoFailure(error)
            diagnostics.error = failure
            diagnostics.targetValid = false
            diagnostics.replacement = "failed"
            transition(to: .failed(failure))
        }
    }

    private func generate(
        _ request: TransformationRequest,
        target: SelectionSnapshot,
        operationID: UUID,
        proposalRequestID: UUID?
    ) async {
        do {
            guard isGenerating(operationID) else { return }
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
            if let proposalRequestID {
                let proposal = TransformationProposal(
                    id: UUID(),
                    requestID: proposalRequestID,
                    targetID: target.id,
                    text: output
                )
                activeOperationID = nil
                generationTask = nil
                diagnostics.error = nil
                diagnostics.generation = "complete"
                diagnostics.replacement = "idle"
                transition(to: .proposal(proposal))
                return
            }
            if output == target.text {
                finish(operationID, unchanged: true)
                return
            }

            do {
                try selectionAccess.validate(target)
                diagnostics.targetValid = true
            } catch {
                diagnostics.targetValid = false
                finish(operationID, failure: Self.validationFailure(error))
                return
            }
            guard isGenerating(operationID) else { return }
            await replace(output, target: target, operationID: operationID)
        } catch {
            guard activeOperationID == operationID else { return }
            finish(operationID, failure: Self.providerFailure(error))
        }
    }

    private func replace(_ output: String, target: SelectionSnapshot, operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        diagnostics.replacement = "running"
        transition(to: .replacing)
        do {
            let receipt = try await selectionAccess.replace(target, with: output)
            guard activeOperationID == operationID, state == .replacing else { return }
            guard receipt.target.id == target.id, receipt.replacement == output else {
                diagnostics.replacement = "failed"
                finish(operationID, failure: .replacementFailed, replacementFailed: true)
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
            diagnostics.strategy = receipt.strategy
            diagnostics.generation = "complete"
            diagnostics.replacement = "replaced"
            transition(to: .succeeded(unchanged: false))
        } catch {
            guard activeOperationID == operationID, state == .replacing else { return }
            let failure = Self.replacementFailure(error)
            if failure == .targetLost || failure == .staleSelection { diagnostics.targetValid = false }
            finish(operationID, failure: failure, replacementFailed: true)
        }
    }

    private func finish(_ operationID: UUID, unchanged: Bool) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        generationTask = nil
        discardTarget()
        diagnostics.error = nil
        diagnostics.generation = "complete"
        diagnostics.replacement = unchanged ? "unchanged" : "replaced"
        transition(to: .succeeded(unchanged: unchanged))
    }

    private func finish(_ operationID: UUID, failure: ImrseError, replacementFailed: Bool = false) {
        guard activeOperationID == operationID else { return }
        invalidateGeneration(cancelTask: false)
        pendingResponseMetadata = nil
        if replacementFailed && failure == .clipboardPending {
            if let previousReceipt = undoReceipt {
                selectionAccess.discard(previousReceipt.target)
            }
            undoReceipt = nil
        }
        discardTarget()
        diagnostics.error = failure
        diagnostics.generation = failure == .cancelled ? "cancelled" : "failed"
        diagnostics.replacement = replacementFailed ? "failed" : "idle"
        transition(to: .failed(failure))
    }

    private func fail(_ failure: ImrseError) {
        responseMetadata = nil
        pendingResponseMetadata = nil
        discardTarget()
        diagnostics.error = failure
        diagnostics.generation = failure == .cancelled ? "cancelled" : "idle"
        diagnostics.replacement = "idle"
        transition(to: .failed(failure))
    }

    private func invalidateGeneration(cancelTask: Bool) {
        let task = generationTask
        activeOperationID = nil
        generationTask = nil
        if cancelTask { task?.cancel() }
    }

    private func discardTarget() {
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
        let length = snapshot.text.utf16.count
        guard length > 0 else { return .noSelection }
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noSelection }
        guard snapshot.text.utf8.count <= maximumSelectionUTF8Bytes else { return .selectionTooLarge }
        if let range = snapshot.range {
            guard range.location >= 0, range.length == length else { return .noSelection }
            let (_, overflow) = range.location.addingReportingOverflow(range.length)
            guard !overflow else { return .noSelection }
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
        (error as? ImrseError) ?? .targetLost
    }

    private static func replacementFailure(_ error: any Error) -> ImrseError {
        guard let error = error as? ImrseError else { return .replacementFailed }
        return switch error {
        case .targetLost, .staleSelection, .clipboardFailed, .clipboardPending, .permissionRequired: error
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
