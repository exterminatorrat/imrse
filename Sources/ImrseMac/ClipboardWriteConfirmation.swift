import Foundation
import ImrseCore

/// Resamples read-only confirmation after a single paste. Never stages or posts.
/// An incoherent AX range/text snapshot is not success and does not permit replay.
enum ClipboardWriteConfirmation {
    static func isTransientSnapshotMismatch(_ error: any Error, reason: SelectionFailureReason?) -> Bool {
        guard reason == .selectedTextLengthMismatch, let error = error as? ImrseError else { return false }
        // SelectedTextRangeFallback reports targetLost; nil readSelection reports staleSelection.
        return error == .targetLost || error == .staleSelection
    }

    @MainActor
    static func wait<Value>(
        deadline: ContinuousClock.Instant,
        now: () -> ContinuousClock.Instant,
        sample: () throws -> Value?,
        waitForUpdate: () async -> Void
    ) async throws -> Value? {
        while now() < deadline {
            try Task.checkCancellation()
            let value = try sample()
            // AX reads can consume the remaining budget. Do not accept overdue proof.
            guard now() < deadline else { return nil }
            if let value { return value }
            await waitForUpdate()
        }
        try Task.checkCancellation()
        return nil
    }
}
