#if os(macOS)
import Foundation

/// Pure transaction experiment. No NSPasteboard, CGEvent, AX, runtime lease or app wiring.
/// A fresh pasteboard version is NOT proof of its producer, selection scope, or write authority.
@MainActor
protocol ExplicitSelectionCopyHost: AnyObject {
    /// Materialize only bounded, eager representations. Reject promises/lazy unsupported items.
    /// The byte limit must be enforced BEFORE allocating data, not just by this coordinator.
    func readClipboard(maximumBytes: Int) -> ExplicitCopyClipboardRead
    /// Must synchronously recheck exact foreground process + pinned target (including secure-field
    /// refusal) immediately before posting Cmd-C at most once. Never focus/activate or retry.
    func dispatchCopyOnce(ifTargetMatches target: ExplicitCopyTarget, operationID: UUID) -> ExplicitCopyDispatch
    /// Only for a positively acknowledged copy owned by this operation. Recheck exact version AND
    /// every representation before restoring. Native NSPasteboard is not CAS: a future adapter
    /// must return uncertain rather than promise atomicity it cannot provide.
    func restoreBackup(_ backup: ExplicitCopyClipboardSnapshot,
                       onlyIfOwned current: ExplicitCopyClipboardSnapshot,
                       operationID: UUID) -> ExplicitCopyRestore
}

struct ExplicitCopyTarget: Equatable, Sendable {
    let processID: Int32
    let applicationID: String
    /// Opaque identifier whose exact AX/editor binding belongs to the future host adapter.
    let targetID: UUID
}
struct ExplicitCopyClipboardRepresentation: Equatable, Sendable {
    let type: String
    let data: Data
}
struct ExplicitCopyClipboardSnapshot: Equatable, Sendable {
    let version: Int
    let items: [[ExplicitCopyClipboardRepresentation]]
    /// Stronger cooperating-host acknowledgement, NOT inferred from changeCount/timing/focus.
    /// Ordinary Cmd-C + NSPasteboard cannot supply this evidence and MUST leave it nil.
    let acknowledgedCopyID: UUID?

    func sameClipboard(as other: Self) -> Bool { version == other.version && items == other.items }
    var isBounded: Bool {
        guard version >= 0, items.count <= 16 else { return false }
        var bytes = 0
        for item in items {
            guard item.count <= 32, Set(item.map(\.type)).count == item.count else { return false }
            for representation in item {
                guard !representation.type.isEmpty, representation.type.utf8.count <= 256,
                      representation.data.count <= ExplicitSelectionCopy.maximumClipboardBytes - bytes else { return false }
                bytes += representation.data.count
            }
        }
        return true
    }
}
enum ExplicitCopyClipboardRead: Sendable {
    case snapshot(ExplicitCopyClipboardSnapshot)
    case unavailable, unsupported, tooLarge
}
enum ExplicitCopyDispatch: Equatable, Sendable { case notDispatched, dispatched, uncertain }
enum ExplicitCopyRestore: Equatable, Sendable { case restored, ownershipLost, uncertain }
enum ExplicitCopyStopReason: Error, Equatable, Sendable {
    case alreadyUsed, cancelled, targetRefused, backupUnavailable, unsupportedClipboard, clipboardTooLarge
    case clipboardChangedBeforeDispatch, dispatchUncertain, noFreshChange, emptyCopy, malformedText
    case clipboardUnavailableAfterDispatch, ambiguousVersion, copyTooLarge, deadlineExceeded
}
enum ExplicitCopyBackupDisposition: Equatable, Sendable {
    case notNeeded, restored, retainedUnresolved, concurrentClipboardPreserved, expiredOrDiscarded
}
enum ExplicitCopyOutcome: Equatable, Sendable {
    case notDispatched(ExplicitCopyStopReason)
    case unresolved(ExplicitCopyStopReason, backup: ExplicitCopyBackupDisposition)
    /// Candidate is session-only. `targetAcknowledged` never proves one editor selection/range.
    case candidate(id: UUID, targetAcknowledged: Bool, backup: ExplicitCopyBackupDisposition)
}

/// One-use bounded Cmd-C transaction coordinator. All capabilities are injected for mock tests.
/// Not an automatic capture fallback: unattributed text requires separate user/source validation.
/// One-second admission/publication deadline starts at run entry, including backup reads.
/// Synchronous host calls cannot be preempted; late completion is rejected, not claimed timely.
@MainActor
final class ExplicitSelectionCopy {
    nonisolated static let maximumClipboardBytes = 4_194_304
    nonisolated static let maximumTextBytes = 1_048_576
    private(set) var outcome: ExplicitCopyOutcome?
    private(set) var isRunning = false
    private var used = false, cancelled = false
    private let host: any ExplicitSelectionCopyHost
    private let now: @MainActor () -> ContinuousClock.Instant
    private let pause: @MainActor () async throws -> Void
    private let timeout: Duration, retention: Duration
    private var backup: ExplicitCopyClipboardSnapshot?
    private var candidate: (id: UUID, text: String)?
    private var expiry: ContinuousClock.Instant?
    private var expiryTask: Task<Void, Never>?

    init(host: any ExplicitSelectionCopyHost) {
        self.host = host
        now = { ContinuousClock.now }
        pause = { try await Task.sleep(for: .milliseconds(20)) }
        timeout = .seconds(1); retention = .seconds(180)
    }
    // Internal deterministic clock/sleep seam for source-only tests.
    init(host: any ExplicitSelectionCopyHost, timeout: Duration = .seconds(1), retention: Duration = .seconds(180),
         now: @escaping @MainActor () -> ContinuousClock.Instant,
         pause: @escaping @MainActor () async throws -> Void) {
        self.host = host; self.timeout = timeout; self.retention = retention
        self.now = now; self.pause = pause
    }

    var hasRetainedBackup: Bool { expireIfNeeded(); return backup != nil }
    /// Explicit inspection/export only. Never stages clipboard or grants generation/paste authority.
    func candidateText(id: UUID) -> String? {
        expireIfNeeded()
        guard !isRunning, let candidate, candidate.id == id else { return nil }
        return candidate.text
    }
    /// Cancellation never authorizes restoration or replay of a potentially late copy event.
    func cancel() {
        cancelled = true
        candidate = nil
        if !isRunning { discardRetainedData() }
    }
    /// Explicitly abandon recovery data. Does not mutate the actual clipboard or reset one-use state.
    func discardRetainedData() {
        guard !isRunning else { cancelled = true; return }
        expiryTask?.cancel(); expiryTask = nil; expiry = nil; backup = nil; candidate = nil
    }

    func run(target: ExplicitCopyTarget) async -> ExplicitCopyOutcome {
        guard !used else { return .notDispatched(.alreadyUsed) }
        used = true; isRunning = true
        let deadline = now().advanced(by: timeout)
        defer { isRunning = false }
        guard !cancelled, !Task.isCancelled else { return end(.notDispatched(.cancelled)) }
        guard target.processID > 0, !target.applicationID.isEmpty, target.applicationID.utf8.count <= 256 else {
            return end(.notDispatched(.targetRefused))
        }
        if let reason = stopReason(deadline: deadline) { return end(.notDispatched(reason)) }
        let original: ExplicitCopyClipboardSnapshot
        let backupRead = host.readClipboard(maximumBytes: Self.maximumClipboardBytes)
        if let reason = stopReason(deadline: deadline) { return end(.notDispatched(reason)) }
        switch backupRead {
        case .snapshot(let snapshot):
            guard snapshot.isBounded else { return end(.notDispatched(.clipboardTooLarge)) }
            original = snapshot
        case .unavailable: return end(.notDispatched(.backupUnavailable))
        case .unsupported: return end(.notDispatched(.unsupportedClipboard))
        case .tooLarge: return end(.notDispatched(.clipboardTooLarge))
        }
        // Do not overwrite clipboard with a marker. If it changed during backup, do not dispatch.
        let beforeRead = host.readClipboard(maximumBytes: Self.maximumClipboardBytes)
        if let reason = stopReason(deadline: deadline) { return end(.notDispatched(reason)) }
        guard case .snapshot(let before) = beforeRead,
              before.isBounded, before.sameClipboard(as: original) else {
            return end(.notDispatched(.clipboardChangedBeforeDispatch))
        }
        guard !cancelled, !Task.isCancelled else { return end(.notDispatched(.cancelled)) }
        backup = original
        let operationID = UUID()
        if let reason = stopReason(deadline: deadline) { backup = nil; return end(.notDispatched(reason)) }
        switch host.dispatchCopyOnce(ifTargetMatches: target, operationID: operationID) {
        case .notDispatched:
            backup = nil
            return end(.notDispatched(stopReason(deadline: deadline) ?? .targetRefused))
        case .uncertain: return end(.unresolved(stopReason(deadline: deadline) ?? .dispatchUncertain, backup: .retainedUnresolved))
        case .dispatched: break
        }
        if let reason = stopReason(deadline: deadline) { return end(.unresolved(reason, backup: .retainedUnresolved)) }
        // Both elapsed time AND poll count bounded. No automatic second dispatch in any branch.
        for _ in 0..<50 {
            guard !cancelled, !Task.isCancelled else { return end(.unresolved(.cancelled, backup: .retainedUnresolved)) }
            guard now() < deadline else { return end(.unresolved(.noFreshChange, backup: .retainedUnresolved)) }
            let freshRead = host.readClipboard(maximumBytes: Self.maximumClipboardBytes)
            if let reason = stopReason(deadline: deadline) { return end(.unresolved(reason, backup: .retainedUnresolved)) }
            switch freshRead {
            case .unavailable: return end(.unresolved(.clipboardUnavailableAfterDispatch, backup: .retainedUnresolved))
            case .unsupported: return end(.unresolved(.unsupportedClipboard, backup: .retainedUnresolved))
            case .tooLarge: return end(.unresolved(.clipboardTooLarge, backup: .retainedUnresolved))
            case .snapshot(let fresh):
                guard fresh.isBounded else { return end(.unresolved(.clipboardTooLarge, backup: .retainedUnresolved)) }
                if fresh.version == original.version {
                    guard fresh.sameClipboard(as: original) else { return end(.unresolved(.ambiguousVersion, backup: .retainedUnresolved)) }
                    break // unchanged clipboard is never a successful copy, even if it already held selected text.
                }
                guard fresh.version > original.version else { return end(.unresolved(.ambiguousVersion, backup: .retainedUnresolved)) }
                // Source attribution is independent of version freshness. Never restore an unattributed
                // clipboard item: it might be the user's concurrent copy rather than our Cmd-C.
                let acknowledged = fresh.acknowledgedCopyID == operationID
                let text = Self.decodeText(fresh)
                let disposition: ExplicitCopyBackupDisposition
                if acknowledged {
                    // A second exact check closes common user-copy races, NOT the native CAS gap.
                    guard !cancelled, !Task.isCancelled else { return end(.unresolved(.cancelled, backup: .retainedUnresolved)) }
                    if let reason = stopReason(deadline: deadline) { return end(.unresolved(reason, backup: .retainedUnresolved)) }
                    let currentRead = host.readClipboard(maximumBytes: Self.maximumClipboardBytes)
                    if let reason = stopReason(deadline: deadline) { return end(.unresolved(reason, backup: .retainedUnresolved)) }
                    if case .snapshot(let current) = currentRead,
                       current.isBounded, current.sameClipboard(as: fresh), current.acknowledgedCopyID == operationID {
                        if let reason = stopReason(deadline: deadline) { return end(.unresolved(reason, backup: .retainedUnresolved)) }
                        switch host.restoreBackup(original, onlyIfOwned: fresh, operationID: operationID) {
                        case .restored: disposition = .restored; backup = nil
                        case .ownershipLost: disposition = .concurrentClipboardPreserved
                        case .uncertain: disposition = .retainedUnresolved
                        }
                    } else { disposition = .concurrentClipboardPreserved }
                } else { disposition = .retainedUnresolved }
                if let reason = stopReason(deadline: deadline) { return end(.unresolved(reason, backup: disposition)) }
                switch text {
                case .success(let value):
                    let id = UUID(); candidate = (id, value)
                    return end(.candidate(id: id, targetAcknowledged: acknowledged, backup: disposition))
                case .failure(let reason): return end(.unresolved(reason, backup: disposition))
                }
            }
            do { try await pause() }
            catch { return end(.unresolved(.cancelled, backup: .retainedUnresolved)) }
        }
        return end(.unresolved(.noFreshChange, backup: .retainedUnresolved))
    }

    private func stopReason(deadline: ContinuousClock.Instant) -> ExplicitCopyStopReason? {
        if cancelled || Task.isCancelled { return .cancelled }
        return now() >= deadline ? .deadlineExceeded : nil
    }

    private static func decodeText(_ snapshot: ExplicitCopyClipboardSnapshot) -> Result<String, ExplicitCopyStopReason> {
        guard !snapshot.items.isEmpty else { return .failure(.emptyCopy) }
        guard snapshot.items.count == 1 else { return .failure(.unsupportedClipboard) }
        guard let representation = snapshot.items[0].first(where: { $0.type == "public.utf8-plain-text" }) else {
            return .failure(.unsupportedClipboard)
        }
        guard representation.data.count <= maximumTextBytes else { return .failure(.copyTooLarge) }
        guard let text = String(data: representation.data, encoding: .utf8) else { return .failure(.malformedText) }
        guard !text.isEmpty else { return .failure(.emptyCopy) }
        guard !text.unicodeScalars.contains(where: { $0.value < 32 && ![9,10,13].contains($0.value) || (127...159).contains($0.value) }) else { return .failure(.malformedText) }
        return .success(text)
    }
    private func end(_ final: ExplicitCopyOutcome) -> ExplicitCopyOutcome {
        outcome = final
        if backup != nil || candidate != nil {
            expiry = now().advanced(by: retention)
            expiryTask = Task { [weak self, retention] in
                do { try await Task.sleep(for: retention) } catch { return }
                self?.discardRetainedData()
            }
        }
        return final
    }
    private func expireIfNeeded() { if let expiry, now() >= expiry { discardRetainedData() } }
}
#endif
