import AppKit
import XCTest
@testable import ImrseMac

@MainActor
final class ClipboardPasteboardTransactionTests: XCTestCase {
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
