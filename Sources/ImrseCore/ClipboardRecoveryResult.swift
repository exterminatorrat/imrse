/// Outcome of an explicit recovery-only request. Neither case claims that an
/// editor was changed, that a paste succeeded, or that an Undo is available.
public enum ClipboardRecoveryResult: Equatable, Sendable {
    case notNeeded
    case restoredClipboardBackup
}
