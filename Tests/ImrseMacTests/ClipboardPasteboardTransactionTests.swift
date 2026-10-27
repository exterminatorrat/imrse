import AppKit
import ImrseCore
import XCTest
@testable import ImrseMac

@MainActor
final class ClipboardPasteboardTransactionTests: XCTestCase {
    private final class RejectingItem: NSPasteboardItem {
        override func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool { false }
    }

    func testStagingConstructionFailureDoesNotClearOriginalClipboard() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let count = pasteboard.changeCount
        var transaction = try ClipboardPasteboardTransaction.capture(from: pasteboard, makeItem: { RejectingItem() })
        XCTAssertThrowsError(try transaction.stage("generated", on: pasteboard))
        XCTAssertFalse(transaction.hasMutatedPasteboard)
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoreConstructionFailurePreservesOwnedBoardAndRecoverableBackup() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        @MainActor
        final class ConstructionState {
            var rejectConstruction = false
        }
        let construction = ConstructionState()
        var transaction = try ClipboardPasteboardTransaction.capture(from: pasteboard, makeItem: {
            construction.rejectConstruction ? RejectingItem() : NSPasteboardItem()
        })
        try transaction.stage("generated", on: pasteboard)
        let stagedCount = pasteboard.changeCount
        construction.rejectConstruction = true
        XCTAssertThrowsError(try transaction.restoreIfOwned(on: pasteboard))
        XCTAssertTrue(transaction.stillOwns(pasteboard))
        XCTAssertEqual(pasteboard.changeCount, stagedCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "generated")
        construction.rejectConstruction = false
        XCTAssertTrue(try transaction.restoreIfOwned(on: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testPostClearRestoreWriteFailureRetainsPendingWithoutRetryOrFurtherPaste() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let recovery = ClipboardPasteRecovery<ClipboardPasteboardTransaction, Int>()
        var captures = 0
        var stages = 0
        var posts = 0
        var confirmations = 0
        var restores = 0
        var writes = 0
        var stagedChangeCount = pasteboard.changeCount
        var transactionAfterRestore: ClipboardPasteboardTransaction?

        @MainActor
        func restore(_ transaction: inout ClipboardPasteboardTransaction) throws -> Bool {
            restores += 1
            defer { transactionAfterRestore = transaction }
            return try transaction.restoreIfOwned(on: pasteboard, writeRestoredItems: { board, items in
                writes += 1
                XCTAssertTrue(board === pasteboard)
                XCTAssertEqual(board.changeCount, stagedChangeCount + 1)
                XCTAssertTrue(board.types?.isEmpty ?? true)
                XCTAssertNil(board.string(forType: .string))
                XCTAssertEqual(items.count, 1)
                XCTAssertEqual(items.first?.string(forType: .string), "original")
                return false
            })
        }

        @MainActor
        func attempt() async throws -> String {
            try await recovery.perform(
                destination: 1,
                capture: {
                    captures += 1
                    return try ClipboardPasteboardTransaction.capture(from: pasteboard)
                },
                stage: {
                    stages += 1
                    try $0.stage("generated", on: pasteboard)
                    stagedChangeCount = pasteboard.changeCount
                },
                verify: { XCTAssertTrue($0.stillOwns(pasteboard)) },
                post: { posts += 1 },
                confirm: {
                    confirmations += 1
                    return "receipt"
                },
                hasMutated: { $0.hasMutatedPasteboard },
                restore: { try restore(&$0) }
            )
        }

        do {
            _ = try await attempt()
            XCTFail("A failed post-clear restore must not return a receipt")
        } catch {
            XCTAssertEqual(error as? ImrseError, .clipboardPending)
        }
        XCTAssertTrue(recovery.isBlocked)
        XCTAssertTrue(try XCTUnwrap(transactionAfterRestore).hasMutatedPasteboard)
        XCTAssertFalse(try XCTUnwrap(transactionAfterRestore).stillOwns(pasteboard))
        XCTAssertEqual(pasteboard.changeCount, stagedChangeCount + 1)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(restores, 1)
        XCTAssertEqual(writes, 1)

        let clearedChangeCount = pasteboard.changeCount
        XCTAssertThrowsError(try recovery.recover(
            terminationConfirmed: { _ in true },
            writeConfirmed: { _ in true },
            restore: { try restore(&$0) }
        )) { XCTAssertEqual($0 as? ImrseError, .clipboardPending) }
        XCTAssertEqual(restores, 2)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(pasteboard.changeCount, clearedChangeCount)
        XCTAssertNil(pasteboard.string(forType: .string))

        do {
            _ = try await attempt()
            XCTFail("Lost ownership must block another clipboard fallback")
        } catch {
            XCTAssertEqual(error as? ImrseError, .clipboardPending)
        }
        XCTAssertTrue(pasteboard.setString("new copy", forType: .string))
        let copiedChangeCount = pasteboard.changeCount
        XCTAssertThrowsError(try recovery.recover(
            terminationConfirmed: { _ in true },
            writeConfirmed: { _ in true },
            restore: { try restore(&$0) }
        )) { XCTAssertEqual($0 as? ImrseError, .clipboardPending) }
        XCTAssertTrue(recovery.isBlocked)
        XCTAssertEqual(pasteboard.changeCount, copiedChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "new copy")
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(stages, 1)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(restores, 3)
        XCTAssertEqual(writes, 1)
    }

    func testRestoresOriginalClipboardWhileUniqueMarkerIsOwned() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))

        var transaction = try ClipboardPasteboardTransaction.capture(from: pasteboard)
        try transaction.stage("temporary", on: pasteboard)

        XCTAssertTrue(transaction.stillOwns(pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "temporary")
        let restored = try transaction.restoreIfOwned(on: pasteboard)
        XCTAssertTrue(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertFalse(transaction.stillOwns(pasteboard))
    }

    func testDoesNotRestoreOverAnIdenticalUserCopy() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))

        var transaction = try ClipboardPasteboardTransaction.capture(from: pasteboard)
        try transaction.stage("same text", on: pasteboard)
        _ = pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("same text", forType: .string))

        XCTAssertFalse(transaction.stillOwns(pasteboard))
        let restored = try transaction.restoreIfOwned(on: pasteboard)
        XCTAssertFalse(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "same text")
    }

    func testRejectsClipboardBackupsAboveTheByteLimit() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1), forType: NSPasteboard.PasteboardType("public.data"))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(try ClipboardPasteboardTransaction.capture(from: pasteboard))
    }

    func testRejectsClipboardBackupsWithTooManyRepresentations() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.clearContents()
        let item = NSPasteboardItem()
        for index in 0..<129 {
            item.setData(Data([UInt8(index % 255)]), forType: NSPasteboard.PasteboardType("com.imrse.tests.type-\(index)"))
        }
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(try ClipboardPasteboardTransaction.capture(from: pasteboard))
    }

    func testRejectsClipboardBackupsWithTooManyItems() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.clearContents()
        let items = (0..<65).map { index in
            let item = NSPasteboardItem()
            item.setString("item-\(index)", forType: .string)
            return item
        }
        XCTAssertTrue(pasteboard.writeObjects(items))

        XCTAssertThrowsError(try ClipboardPasteboardTransaction.capture(from: pasteboard))
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.imrse.tests.\(UUID().uuidString)"))
    }
}
