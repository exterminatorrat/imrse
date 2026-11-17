#if os(macOS)
import Foundation
import Testing
@testable import ImrseMac

@MainActor
struct ExplicitSelectionCopyTests {
    private let target = ExplicitCopyTarget(processID: 42, applicationID: "synthetic.editor", targetID: UUID())

    @Test func freshTextIsCandidateNotProducerProofAndDoesNotRestoreUnattributedClipboard() async {
        let f = CopyFixture()
        f.host.onDispatch = { _, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2)) }
        let outcome = await f.session.run(target: target)
        guard case .candidate(let id, let acknowledged, let backup) = outcome else { Issue.record("Expected candidate"); return }
        #expect(!acknowledged); #expect(backup == .retainedUnresolved)
        #expect(f.session.candidateText(id: id) == "selected")
        #expect(f.session.candidateText(id: UUID()) == nil)
        #expect(f.host.posts == 1); #expect(f.host.restoreCalls == 0)
        #expect(f.session.hasRetainedBackup)
    }

    @Test func cooperatingHostAcknowledgementAllowsExactConditionalRestore() async {
        let f = CopyFixture()
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2, id: id)) }
        let outcome = await f.session.run(target: target)
        guard case .candidate(let id, true, .restored) = outcome else { Issue.record("Expected acknowledged candidate"); return }
        #expect(f.session.candidateText(id: id) == "selected")
        #expect(f.host.restoreCalls == 1); #expect(!f.session.hasRetainedBackup)
        #expect(f.host.lastBackup?.items == copySnapshot("original clipboard", version: 1).items)
    }

    @Test func targetGuardRefusalNeverPostsCopyOrWritesClipboard() async {
        let f = CopyFixture(); f.host.dispatch = .notDispatched
        #expect(await f.session.run(target: target) == .notDispatched(.targetRefused))
        #expect(f.host.posts == 0); #expect(f.host.restoreCalls == 0); #expect(!f.session.hasRetainedBackup)
    }

    @Test func clipboardChangeDuringBackupPreventsDispatch() async {
        let f = CopyFixture()
        f.host.onRead = { n, host in if n == 2 { host.clipboard = .snapshot(copySnapshot("user copy", version: 2)) } }
        #expect(await f.session.run(target: target) == .notDispatched(.clipboardChangedBeforeDispatch))
        #expect(f.host.dispatchCalls == 0); #expect(f.host.restoreCalls == 0)
    }

    @Test func timeoutNeverReplaysOrRestoresAndLateCopyStaysUnclaimed() async {
        let f = CopyFixture()
        #expect(await f.session.run(target: target) == .unresolved(.noFreshChange, backup: .retainedUnresolved))
        #expect(f.host.posts == 1); #expect(f.host.restoreCalls == 0); #expect(f.session.hasRetainedBackup)
        f.host.clipboard = .snapshot(copySnapshot("late asynchronous copy", version: 2))
        #expect(await f.session.run(target: target) == .notDispatched(.alreadyUsed))
        #expect(f.host.posts == 1); #expect(f.host.restoreCalls == 0)
    }

    @Test func unchangedExistingTextNeverCountsAsSuccessfulCopy() async {
        let f = CopyFixture(); f.host.clipboard = .snapshot(copySnapshot("selected", version: 1))
        #expect(await f.session.run(target: target) == .unresolved(.noFreshChange, backup: .retainedUnresolved))
    }

    @Test func freshVersionWithIdenticalBytesIsStillOnlyCandidate() async {
        let f = CopyFixture()
        f.host.onDispatch = { _, host in host.clipboard = .snapshot(copySnapshot("original clipboard", version: 2)) }
        guard case .candidate(_, false, .retainedUnresolved) = await f.session.run(target: target) else { Issue.record("Fresh version missing"); return }
        #expect(f.host.restoreCalls == 0)
    }

    @Test(arguments: [0, 1, 2, 3]) func invalidFreshClipboardHasClosedOutcome(_ kind: Int) async {
        let f = CopyFixture()
        f.host.onDispatch = { _, host in
            let representations: [ExplicitCopyClipboardRepresentation]
            switch kind {
            case 0: representations = [.init(type: "public.utf8-plain-text", data: Data())]
            case 1: representations = [.init(type: "public.png", data: Data([1]))]
            case 2: representations = [.init(type: "public.utf8-plain-text", data: Data([0xff]))]
            default: representations = [.init(type: "public.utf8-plain-text", data: Data(repeating: 97, count: ExplicitSelectionCopy.maximumTextBytes + 1))]
            }
            host.clipboard = .snapshot(.init(version: 2, items: [representations], acknowledgedCopyID: nil))
        }
        let reason: ExplicitCopyStopReason = [.emptyCopy, .unsupportedClipboard, .malformedText, .copyTooLarge][kind]
        #expect(await f.session.run(target: target) == .unresolved(reason, backup: .retainedUnresolved))
        #expect(f.host.posts == 1); #expect(f.host.restoreCalls == 0)
    }

    @Test(arguments: [0, 1, 2]) func backupMustBeRepresentableAndBoundedBeforeCopy(_ kind: Int) async {
        let f = CopyFixture()
        f.host.clipboard = kind == 0 ? .unavailable : kind == 1 ? .unsupported : .tooLarge
        let reason: ExplicitCopyStopReason = [.backupUnavailable, .unsupportedClipboard, .clipboardTooLarge][kind]
        #expect(await f.session.run(target: target) == .notDispatched(reason))
        #expect(f.host.dispatchCalls == 0); #expect(f.host.restoreCalls == 0)
    }

    @Test func oversizedMaterializedBackupFailsDefensiveBound() async {
        let f = CopyFixture()
        f.host.clipboard = .snapshot(.init(version: 1, items: [[.init(type: "public.data", data: Data(repeating: 0, count: ExplicitSelectionCopy.maximumClipboardBytes + 1))]], acknowledgedCopyID: nil))
        #expect(await f.session.run(target: target) == .notDispatched(.clipboardTooLarge))
        #expect(f.host.posts == 0)
    }

    @Test func concurrentUserCopyBeforeRestoreIsNeverOverwritten() async {
        let f = CopyFixture()
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2, id: id)) }
        f.host.onRead = { n, host in if n == 4 { host.clipboard = .snapshot(copySnapshot("user copy", version: 3)) } }
        guard case .candidate(_, true, .concurrentClipboardPreserved) = await f.session.run(target: target) else { Issue.record("Expected preserved clipboard"); return }
        #expect(f.host.restoreCalls == 0); #expect(f.session.hasRetainedBackup)
        #expect(f.host.clipboardText == "user copy")
    }

    @Test func concurrentUserCopyAtConditionalRestoreIsNotOverwritten() async {
        let f = CopyFixture()
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2, id: id)) }
        f.host.beforeRestore = { host in host.clipboard = .snapshot(copySnapshot("new user copy", version: 3)) }
        guard case .candidate(_, true, .concurrentClipboardPreserved) = await f.session.run(target: target) else { Issue.record("Expected lost ownership"); return }
        #expect(f.host.clipboardText == "new user copy"); #expect(f.host.restoreCalls == 1)
    }

    @Test func uncertainRestoreRetainsBackupWithoutRetry() async {
        let f = CopyFixture(); f.host.restoreResult = .uncertain
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2, id: id)) }
        guard case .candidate(_, true, .retainedUnresolved) = await f.session.run(target: target) else { Issue.record("Expected uncertain restoration"); return }
        #expect(f.host.restoreCalls == 1); #expect(f.session.hasRetainedBackup)
    }

    @Test func uncertainDispatchRetainsBackupWithoutPollingOrReplay() async {
        let f = CopyFixture(); f.host.dispatch = .uncertain
        #expect(await f.session.run(target: target) == .unresolved(.dispatchUncertain, backup: .retainedUnresolved))
        #expect(f.host.reads == 2); #expect(f.host.dispatchCalls == 1); #expect(f.host.restoreCalls == 0)
        #expect(f.session.hasRetainedBackup)
    }

    @Test func cancellationBeforeDispatchDoesNothing() async {
        let f = CopyFixture(); f.session.cancel()
        #expect(await f.session.run(target: target) == .notDispatched(.cancelled))
        #expect(f.host.posts == 0); #expect(f.host.reads == 0)
    }

    @Test func cancellationDuringWaitRetainsUnresolvedBackupAndNeverRestores() async {
        let f = CopyFixture(); f.onPause = { f.session.cancel() }
        #expect(await f.session.run(target: target) == .unresolved(.cancelled, backup: .retainedUnresolved))
        #expect(f.host.posts == 1); #expect(f.host.restoreCalls == 0); #expect(f.session.hasRetainedBackup)
        f.onPause = nil
    }

    @Test func cancellationAtFinalReadPreventsRestorationAndCandidatePublication() async {
        let f = CopyFixture()
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2, id: id)) }
        f.host.onRead = { n, _ in if n == 4 { f.session.cancel() } }
        #expect(await f.session.run(target: target) == .unresolved(.cancelled, backup: .retainedUnresolved))
        #expect(f.host.restoreCalls == 0); #expect(f.session.hasRetainedBackup)
        f.host.onRead = nil
    }

    @Test func versionRegressionAndSameVersionMutationAreAmbiguous() async {
        for version in [0, 1] {
            let f = CopyFixture(); f.host.onDispatch = { _, host in host.clipboard = .snapshot(copySnapshot("mutated", version: version)) }
            #expect(await f.session.run(target: target) == .unresolved(.ambiguousVersion, backup: .retainedUnresolved))
            #expect(f.host.restoreCalls == 0)
        }
    }

    @Test func retentionExpiryDropsCandidateAndBackupWithoutClipboardAction() async {
        let f = CopyFixture(); f.host.onDispatch = { _, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2)) }
        guard case .candidate(let id, _, _) = await f.session.run(target: target) else { Issue.record("Expected candidate"); return }
        f.clock = f.clock.advanced(by: .seconds(181))
        #expect(f.session.candidateText(id: id) == nil); #expect(!f.session.hasRetainedBackup)
        #expect(f.host.restoreCalls == 0); #expect(f.host.clipboardText == "selected")
    }

    @Test(arguments: [1, 2]) func backupReadDeadlinePreventsAnyDispatch(_ delayedRead: Int) async {
        let f = CopyFixture()
        f.host.onRead = { n, _ in if n == delayedRead { f.clock = f.clock.advanced(by: .seconds(2)) } }
        #expect(await f.session.run(target: target) == .notDispatched(.deadlineExceeded))
        #expect(f.host.posts == 0); #expect(f.host.restoreCalls == 0); #expect(!f.session.hasRetainedBackup)
        f.host.onRead = nil
    }

    @Test func delayedDispatchCompletionNeverPublishesOrReplays() async {
        let f = CopyFixture()
        f.host.onDispatch = { id, host in
            host.clipboard = .snapshot(copySnapshot("late selected", version: 2, id: id))
            f.clock = f.clock.advanced(by: .seconds(2))
        }
        #expect(await f.session.run(target: target) == .unresolved(.deadlineExceeded, backup: .retainedUnresolved))
        #expect(f.host.reads == 2); #expect(f.host.posts == 1); #expect(f.host.restoreCalls == 0)
        #expect(f.session.hasRetainedBackup)
        #expect(await f.session.run(target: target) == .notDispatched(.alreadyUsed))
        f.host.onDispatch = nil
    }

    @Test(arguments: [false, true]) func lateFreshReadNeverPublishesCandidateOrRestores(_ acknowledged: Bool) async {
        let f = CopyFixture()
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("late selected", version: 2, id: acknowledged ? id : nil)) }
        f.host.onRead = { n, _ in if n == 3 { f.clock = f.clock.advanced(by: .seconds(2)) } }
        #expect(await f.session.run(target: target) == .unresolved(.deadlineExceeded, backup: .retainedUnresolved))
        #expect(f.host.posts == 1); #expect(f.host.restoreCalls == 0); #expect(f.session.hasRetainedBackup)
        f.host.onRead = nil
    }

    @Test func lateOwnershipRecheckCannotRestore() async {
        let f = CopyFixture()
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2, id: id)) }
        f.host.onRead = { n, _ in if n == 4 { f.clock = f.clock.advanced(by: .seconds(2)) } }
        #expect(await f.session.run(target: target) == .unresolved(.deadlineExceeded, backup: .retainedUnresolved))
        #expect(f.host.restoreCalls == 0); #expect(f.session.hasRetainedBackup)
        f.host.onRead = nil
    }

    @Test(arguments: [ExplicitCopyRestore.restored, .ownershipLost, .uncertain])
    func lateRestorationNeverPublishesCandidateAndPreservesActualRecoveryStatus(_ restoration: ExplicitCopyRestore) async {
        let f = CopyFixture(); f.host.restoreResult = restoration
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2, id: id)) }
        f.host.beforeRestore = { _ in f.clock = f.clock.advanced(by: .seconds(2)) }
        let disposition: ExplicitCopyBackupDisposition = restoration == .restored ? .restored : restoration == .ownershipLost ? .concurrentClipboardPreserved : .retainedUnresolved
        #expect(await f.session.run(target: target) == .unresolved(.deadlineExceeded, backup: disposition))
        #expect(f.host.restoreCalls == 1); #expect(f.host.posts == 1)
        #expect(f.session.hasRetainedBackup == (restoration != .restored))
        #expect(await f.session.run(target: target) == .notDispatched(.alreadyUsed))
        #expect(f.host.restoreCalls == 1)
        f.host.beforeRestore = nil
    }

    @Test func cancellationInsideRestorationNeverPublishesCandidate() async {
        let f = CopyFixture()
        f.host.onDispatch = { id, host in host.clipboard = .snapshot(copySnapshot("selected", version: 2, id: id)) }
        f.host.beforeRestore = { _ in f.session.cancel() }
        #expect(await f.session.run(target: target) == .unresolved(.cancelled, backup: .restored))
        #expect(f.host.restoreCalls == 1); #expect(!f.session.hasRetainedBackup)
        f.host.beforeRestore = nil
    }

    @Test func fixedClockStillStopsAtFiftyPolls() async {
        let f = CopyFixture(); f.advanceClock = false
        #expect(await f.session.run(target: target) == .unresolved(.noFreshChange, backup: .retainedUnresolved))
        #expect(f.host.reads == 52); #expect(f.host.posts == 1)
    }
}

private func copySnapshot(_ text: String, version: Int, id: UUID? = nil) -> ExplicitCopyClipboardSnapshot {
    .init(version: version, items: [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]], acknowledgedCopyID: id)
}
@MainActor private final class CopyFixture {
    let host = CopyHost()
    var clock = ContinuousClock.now, advanceClock = true
    var onPause: (() -> Void)?
    var session: ExplicitSelectionCopy!
    init() {
        session = ExplicitSelectionCopy(host: host, timeout: .seconds(1), retention: .seconds(180),
            now: { @MainActor [unowned self] in self.clock }, pause: { @MainActor [unowned self] in
                if self.advanceClock { self.clock = self.clock.advanced(by: .milliseconds(20)) }
                self.onPause?(); await Task.yield()
            })
    }
}
@MainActor private final class CopyHost: ExplicitSelectionCopyHost {
    var clipboard: ExplicitCopyClipboardRead = .snapshot(copySnapshot("original clipboard", version: 1))
    var reads = 0, dispatchCalls = 0, posts = 0, restoreCalls = 0
    var dispatch: ExplicitCopyDispatch = .dispatched, restoreResult: ExplicitCopyRestore = .restored
    var onRead: ((Int, CopyHost) -> Void)?, onDispatch: ((UUID, CopyHost) -> Void)?, beforeRestore: ((CopyHost) -> Void)?
    var lastBackup: ExplicitCopyClipboardSnapshot?
    var clipboardText: String? {
        guard case .snapshot(let snapshot) = clipboard, let data = snapshot.items.first?.first?.data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func readClipboard(maximumBytes: Int) -> ExplicitCopyClipboardRead { #expect(maximumBytes == ExplicitSelectionCopy.maximumClipboardBytes); reads += 1; onRead?(reads, self); return clipboard }
    func dispatchCopyOnce(ifTargetMatches target: ExplicitCopyTarget, operationID: UUID) -> ExplicitCopyDispatch {
        dispatchCalls += 1
        if dispatch != .notDispatched { posts += 1; onDispatch?(operationID, self) }
        return dispatch
    }
    func restoreBackup(_ backup: ExplicitCopyClipboardSnapshot, onlyIfOwned current: ExplicitCopyClipboardSnapshot, operationID: UUID) -> ExplicitCopyRestore {
        restoreCalls += 1; beforeRestore?(self)
        guard case .snapshot(let actual) = clipboard, actual.sameClipboard(as: current), actual.acknowledgedCopyID == operationID else { return .ownershipLost }
        lastBackup = backup
        if restoreResult == .restored { clipboard = .snapshot(backup) }
        return restoreResult
    }
}
#endif
