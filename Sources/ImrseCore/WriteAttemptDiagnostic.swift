/// Closed, content-free evidence about a write attempt, including failed attempts.
public struct WriteAttemptDiagnostic: Equatable, Sendable {
    public enum SetterStatus: String, Sendable { case accepted, rejected }
    public enum Readback: String, Sendable { case original, expected, other, unavailable }
    public var strategy: ReplacementStrategy
    public var setterStatus: SetterStatus?
    public var readback: Readback?
    public var clipboardConfirmation: ClipboardConfirmationDiagnostic?
    public init(strategy: ReplacementStrategy) { self.strategy = strategy }
}
