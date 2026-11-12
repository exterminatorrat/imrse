import ImrseCore

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
