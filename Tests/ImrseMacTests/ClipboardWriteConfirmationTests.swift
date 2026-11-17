import Foundation
import ImrseCore
import XCTest
@testable import ImrseMac

@MainActor
final class ClipboardWriteConfirmationTests: XCTestCase {
    func testOnlyFreshLengthMismatchIsEligibleForReadOnlyResampling() {
        for error in ImrseError.allCases {
            let expected = error == .targetLost || error == .staleSelection
            XCTAssertEqual(ClipboardWriteConfirmation.isTransientSnapshotMismatch(error, reason: .selectedTextLengthMismatch), expected)
            XCTAssertFalse(ClipboardWriteConfirmation.isTransientSnapshotMismatch(error, reason: .foregroundApplicationChanged))
            XCTAssertFalse(ClipboardWriteConfirmation.isTransientSnapshotMismatch(error, reason: nil))
        }
        XCTAssertFalse(ClipboardWriteConfirmation.isTransientSnapshotMismatch(CancellationError(), reason: .selectedTextLengthMismatch))
    }
    func testIncoherentReadThenExactProofIsOnePostAndOneRestore() async throws {
        var now = ContinuousClock.now
        let deadline = now.advanced(by: .milliseconds(500))
        var reads = 0, posts = 0, restores = 0
        let recovery = ClipboardPasteRecovery<Bool, Int>()
        let result = try await recovery.perform(destination: 1, capture: { false }, stage: { $0 = true }, verify: { _ in }, post: { posts += 1 }, confirm: {
            try await ClipboardWriteConfirmation.wait(deadline: deadline, now: { now }, sample: {
                reads += 1
                var reason: SelectionFailureReason?
                do {
                    if reads == 1 { reason = .selectedTextLengthMismatch; throw ImrseError.targetLost }
                    return "exact full-value and selection proof"
                } catch {
                    guard ClipboardWriteConfirmation.isTransientSnapshotMismatch(error, reason: reason) else { throw error }
                    return nil
                }
            }, waitForUpdate: { now = now.advanced(by: .milliseconds(20)) })
        }, hasMutated: { $0 }, restore: { _ in restores += 1; return true })
        XCTAssertNotNil(result); XCTAssertEqual(reads, 2); XCTAssertEqual(posts, 1); XCTAssertEqual(restores, 1); XCTAssertFalse(recovery.isBlocked)
    }
    func testPersistentIncoherenceRetainsPendingClipboardWithoutReplay() async {
        var now = ContinuousClock.now
        let deadline = now.advanced(by: .milliseconds(500))
        var posts = 0, restores = 0, reads = 0
        let recovery = ClipboardPasteRecovery<Bool, Int>()
        do {
            let _: String = try await recovery.perform(destination: 1, capture: { false }, stage: { $0 = true }, verify: { _ in }, post: { posts += 1 }, confirm: {
                let result: String? = try await ClipboardWriteConfirmation.wait(deadline: deadline, now: { now }, sample: { reads += 1; return nil }, waitForUpdate: { now = now.advanced(by: .milliseconds(20)) })
                guard let result else { throw ImrseError.replacementFailed }; return result
            }, hasMutated: { $0 }, restore: { _ in restores += 1; return true })
            XCTFail("expected pending")
        } catch { XCTAssertEqual(error as? ImrseError, .clipboardPending) }
        XCTAssertEqual(posts, 1); XCTAssertEqual(restores, 0); XCTAssertEqual(reads, 25); XCTAssertTrue(recovery.isBlocked)
    }
    func testDestinationOrSecurityFailureStopsWithoutFurtherReads() async {
        for expectedError in [ImrseError.targetLost, .secureInput, .unsupportedEditor, .permissionRequired] {
            var reads = 0, waits = 0
            let now = ContinuousClock.now
            do {
                let _: String? = try await ClipboardWriteConfirmation.wait(deadline: now.advanced(by: .milliseconds(500)), now: { now }, sample: { reads += 1; throw expectedError }, waitForUpdate: { waits += 1 })
                XCTFail("expected refusal")
            } catch { XCTAssertEqual(error as? ImrseError, expectedError) }
            XCTAssertEqual(reads, 1); XCTAssertEqual(waits, 0)
        }
    }
    func testProofAfterDeadlineIsNotAccepted() async throws {
        var now = ContinuousClock.now
        let deadline = now.advanced(by: .milliseconds(500))
        let result = try await ClipboardWriteConfirmation.wait(deadline: deadline, now: { now }, sample: { now = deadline; return "late proof" }, waitForUpdate: {})
        XCTAssertNil(result)
    }
}

extension ClipboardWriteConfirmationTests {
    func testPreflightMismatchNeverPostsAndRestoresStagedClipboard() async {
        var posts = 0, restores = 0, confirms = 0
        let recovery = ClipboardPasteRecovery<Bool, Int>()
        do {
            let _: String = try await recovery.perform(destination: 1, capture: { false }, stage: { $0 = true }, verify: { _ in throw ImrseError.staleSelection }, post: { posts += 1 }, confirm: { confirms += 1; return "unreachable" }, hasMutated: { $0 }, restore: { _ in restores += 1; return true })
            XCTFail("expected refusal")
        } catch { XCTAssertEqual(error as? ImrseError, .staleSelection) }
        XCTAssertEqual(posts, 0); XCTAssertEqual(confirms, 0); XCTAssertEqual(restores, 1); XCTAssertFalse(recovery.isBlocked)
    }
}


extension ClipboardWriteConfirmationTests {
    func testCancellationBeforeReadAndAfterWaitNeverAcceptsProof() async {
        for beforeRead in [true, false] {
            var reads = 0, waits = 0
            let now = ContinuousClock.now
            let task = Task { @MainActor in
                try await ClipboardWriteConfirmation.wait(deadline: now.advanced(by: .milliseconds(500)), now: { now }, sample: { reads += 1; return Optional<String>.none }, waitForUpdate: {
                    waits += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                })
            }
            if beforeRead { task.cancel() }
            do { _ = try await task.value; XCTFail("expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(reads, beforeRead ? 0 : 1); XCTAssertEqual(waits, beforeRead ? 0 : 1)
        }
    }
}
