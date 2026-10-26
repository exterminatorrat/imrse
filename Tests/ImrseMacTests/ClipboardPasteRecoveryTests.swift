import Foundation
import ImrseCore
import XCTest
@testable import ImrseMac

@MainActor
final class ClipboardPasteRecoveryTests: XCTestCase {
    private struct Transaction {
        var mutated = false
    }

    @MainActor
    private final class Fixture {
        var recovery: ClipboardPasteRecovery<Transaction, Int>? = .init()
        var board = "original"
        var captures = 0
        var posts = 0
        var restores = 0
        var owns = true
        var captureError: ImrseError?
        var stageError: ImrseError?
        var verifyError: ImrseError?
        var confirmError: ImrseError?
        var restoreError: ImrseError?
        var onVerify: (() -> Void)?
        var onPost: (() -> Void)?
        var onConfirm: (@MainActor () async throws -> Void)?

        func run() async throws -> String {
            guard let recovery else { throw ImrseError.clipboardPending }
            return try await recovery.perform(
                destination: 1,
                capture: {
                    self.captures += 1
                    if let error = self.captureError { throw error }
                    return Transaction()
                },
                stage: {
                    $0.mutated = true
                    self.board = "generated"
                    if let error = self.stageError { throw error }
                },
                verify: { _ in
                    self.onVerify?()
                    if let error = self.verifyError { throw error }
                },
                post: {
                    self.posts += 1
                    self.onPost?()
                },
                confirm: {
                    try await self.onConfirm?()
                    if let error = self.confirmError { throw error }
                    return "receipt"
                },
                hasMutated: { $0.mutated },
                restore: { try self.restore(&$0) }
            )
        }

        func restore(_ transaction: inout Transaction) throws -> Bool {
            restores += 1
            if let restoreError { throw restoreError }
            guard owns else { return false }
            board = "original"
            transaction.mutated = false
            return true
        }

        func recover(terminated: Bool = false, written: Bool = false) throws {
            try recovery?.recover(
                terminationConfirmed: { $0 == 1 && terminated },
                writeConfirmed: { $0 == 1 && written },
                restore: { try self.restore(&$0) }
            )
        }
    }

    func testConfirmedWriteRestoresAndReturnsReceipt() async throws {
        let fixture = Fixture()
        let receipt = try await fixture.run()
        XCTAssertEqual(receipt, "receipt")
        XCTAssertEqual(fixture.posts, 1)
        XCTAssertEqual(fixture.restores, 1)
        XCTAssertEqual(fixture.board, "original")
        XCTAssertFalse(try XCTUnwrap(fixture.recovery).isBlocked)
    }

    func testTimeoutDoesNotRestoreOrAllowAnotherTransaction() async {
        let fixture = Fixture()
        fixture.confirmError = .replacementFailed
        await assertPending(fixture)
        XCTAssertEqual(fixture.board, "generated")
        XCTAssertEqual(fixture.posts, 1)
        XCTAssertEqual(fixture.restores, 0)
        await assertPending(fixture)
        XCTAssertEqual(fixture.captures, 1)
        XCTAssertEqual(fixture.posts, 1)
    }

    func testThrownReadbackDoesNotRestore() async {
        let fixture = Fixture()
        fixture.confirmError = .staleSelection
        await assertPending(fixture)
        XCTAssertEqual(fixture.restores, 0)
        XCTAssertEqual(fixture.board, "generated")
        XCTAssertThrowsError(try fixture.recovery?.recover(
            terminationConfirmed: { _ in false },
            writeConfirmed: { _ in throw ImrseError.staleSelection },
            restore: { try fixture.restore(&$0) }
        ))
        XCTAssertEqual(fixture.restores, 0)
    }

    func testNoElapsedTimeOrUnconfirmedRecoveryReleasesPendingPaste() async {
        let fixture = Fixture()
        fixture.confirmError = .replacementFailed
        await assertPending(fixture)
        for _ in 0..<3 {
            XCTAssertThrowsError(try fixture.recover())
        }
        XCTAssertEqual(fixture.restores, 0)
        XCTAssertEqual(fixture.board, "generated")
    }

    func testDelayedAttributedWriteCanRecoverWithoutCreatingLateReceiptOrReposting() async throws {
        let fixture = Fixture()
        fixture.confirmError = .replacementFailed
        await assertPending(fixture)
        try fixture.recover(written: true)
        XCTAssertFalse(try XCTUnwrap(fixture.recovery).isBlocked)
        XCTAssertEqual(fixture.restores, 1)
        XCTAssertEqual(fixture.posts, 1)
        XCTAssertEqual(fixture.board, "original")
    }

    func testExactDestinationTerminationCanRecover() async throws {
        let fixture = Fixture()
        fixture.confirmError = .replacementFailed
        await assertPending(fixture)
        try fixture.recover(terminated: true)
        XCTAssertFalse(try XCTUnwrap(fixture.recovery).isBlocked)
        XCTAssertEqual(fixture.restores, 1)
        XCTAssertEqual(fixture.posts, 1)
    }

    func testOwnershipLossNeverOverwritesNewClipboardOrReleasesPendingTransaction() async {
        let fixture = Fixture()
        fixture.confirmError = .replacementFailed
        await assertPending(fixture)
        fixture.owns = false
        fixture.board = "new copy"
        XCTAssertThrowsError(try fixture.recover(terminated: true))
        XCTAssertEqual(fixture.board, "new copy")
        await assertPending(fixture)
        XCTAssertEqual(fixture.posts, 1)
        XCTAssertEqual(fixture.captures, 1)
    }

    func testStaleTargetBeforeDispatchRestoresWithoutPosting() async {
        let fixture = Fixture()
        fixture.verifyError = .staleSelection
        do {
            _ = try await fixture.run()
            XCTFail("A stale target must fail")
        } catch {
            XCTAssertEqual(error as? ImrseError, .staleSelection)
        }
        XCTAssertEqual(fixture.posts, 0)
        XCTAssertEqual(fixture.restores, 1)
        XCTAssertEqual(fixture.board, "original")
        XCTAssertFalse(fixture.recovery?.isBlocked ?? true)
    }

    func testReentrantTransactionCannotCaptureStageOrPost() async throws {
        let fixture = Fixture()
        fixture.onConfirm = {
            await self.assertPending(fixture)
            XCTAssertEqual(fixture.captures, 1)
            XCTAssertEqual(fixture.posts, 1)
        }
        _ = try await fixture.run()
        XCTAssertEqual(fixture.captures, 1)
        XCTAssertEqual(fixture.posts, 1)
    }

    func testPostClearStagingFailureWithoutOwnershipRetainsBackupAndBlocks() async {
        let fixture = Fixture()
        fixture.stageError = .clipboardFailed
        fixture.owns = false
        await assertPending(fixture)
        XCTAssertEqual(fixture.posts, 0)
        XCTAssertTrue(fixture.recovery?.isBlocked ?? false)
        await assertPending(fixture)
        XCTAssertEqual(fixture.captures, 1)
    }

    func testPreClearCaptureFailureDoesNotOccupyPendingSlot() async throws {
        let fixture = Fixture()
        fixture.captureError = .clipboardFailed
        do {
            _ = try await fixture.run()
            XCTFail("Capture should fail")
        } catch {
            XCTAssertEqual(error as? ImrseError, .clipboardFailed)
        }
        XCTAssertFalse(fixture.recovery?.isBlocked ?? true)
        XCTAssertEqual(fixture.board, "original")
        fixture.captureError = nil
        _ = try await fixture.run()
        XCTAssertEqual(fixture.posts, 1)
    }

    func testRestoreFailureIsNotRetriedInTheSameAttempt() async {
        let fixture = Fixture()
        fixture.restoreError = .clipboardFailed
        await assertPending(fixture)
        XCTAssertEqual(fixture.restores, 1)
        XCTAssertEqual(fixture.posts, 1)
        XCTAssertTrue(fixture.recovery?.isBlocked ?? false)
    }

    func testCancellationBeforeDispatchRestoresAndDoesNotPost() async {
        let fixture = Fixture()
        fixture.onVerify = { withUnsafeCurrentTask { $0?.cancel() } }
        await Task { @MainActor in
            do {
                _ = try await fixture.run()
                XCTFail("Cancelled attempt must fail")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }.value
        XCTAssertEqual(fixture.posts, 0)
        XCTAssertEqual(fixture.restores, 1)
        XCTAssertFalse(fixture.recovery?.isBlocked ?? true)
    }

    func testCancellationAfterDispatchRetainsPendingWithoutReceipt() async {
        let fixture = Fixture()
        fixture.onPost = { withUnsafeCurrentTask { $0?.cancel() } }
        await Task { @MainActor in await self.assertPending(fixture) }.value
        XCTAssertEqual(fixture.posts, 1)
        XCTAssertEqual(fixture.restores, 0)
        XCTAssertEqual(fixture.board, "generated")
    }

    func testShutdownDoesNotRestorePossiblyQueuedPaste() async {
        let fixture = Fixture()
        fixture.confirmError = .replacementFailed
        await assertPending(fixture)
        fixture.recovery = nil
        XCTAssertEqual(fixture.board, "generated")
        XCTAssertEqual(fixture.restores, 0)
        XCTAssertEqual(fixture.posts, 1)
    }

    func testTerminationRequiresExactProcessIncarnationNotReusedPIDOrAbsence() {
        let identity = ClipboardDestinationIdentity(
            processID: 42,
            launchDate: Date(timeIntervalSince1970: 10),
            executableURL: URL(fileURLWithPath: "/owned/browser"),
            applicationID: "owned.browser"
        )
        let reusedPID = ClipboardDestinationIdentity(
            processID: 42,
            launchDate: Date(timeIntervalSince1970: 20),
            executableURL: identity.executableURL,
            applicationID: identity.applicationID
        )
        XCTAssertFalse(identity.confirmsTermination(observed: identity, isTerminated: false))
        XCTAssertFalse(identity.confirmsTermination(observed: nil, isTerminated: true))
        XCTAssertFalse(identity.confirmsTermination(observed: reusedPID, isTerminated: true))
        XCTAssertTrue(identity.confirmsTermination(observed: identity, isTerminated: true))
    }

    private func assertPending(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await fixture.run()
            XCTFail("No receipt is permitted", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ImrseError, .clipboardPending, file: file, line: line)
        }
    }
}
