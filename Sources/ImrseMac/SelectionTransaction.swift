import ImrseCore
import Foundation

@MainActor
final class ReplacementDispatchState {
    private(set) var dispatched = false

    func perform<Output>(_ action: () -> Output) throws -> Output {
        try Task.checkCancellation()
        markDispatched()
        return action()
    }

    func markDispatched() {
        dispatched = true
    }

    func failure(_ error: any Error, invalidatesPriorUndo: Bool) -> ReplacementOutcome {
        let failure = (error as? ImrseError) ?? (error is CancellationError ? .cancelled : .replacementFailed)
        return dispatched ? .unconfirmed(failure) : .notWritten(failure, invalidatesPriorUndo: invalidatesPriorUndo)
    }
}

enum SelectionMutationOutcome<Applied> {
    case confirmedApplied(Applied)
    case provedNotApplied
    case indeterminate(SelectionFailureReason)

    var allowsFallback: Bool {
        if case .provedNotApplied = self { return true }
        return false
    }
}

struct SelectionWriteCapabilities {
    let selectedTextSettable: Bool
    let permitsWholeValueWrite: Bool
    let clipboardFallbackEnabled: Bool

    func canConsider(_ strategy: ReplacementStrategy) -> Bool {
        switch strategy {
        case .selectedText: selectedTextSettable
        case .valueRange: permitsWholeValueWrite
        case .clipboard: clipboardFallbackEnabled
        }
    }
}
