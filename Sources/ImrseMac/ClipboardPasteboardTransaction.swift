#if os(macOS)
import AppKit
import Foundation
import ImrseCore

public typealias ClipboardPastePreparation = @MainActor () async throws -> Void

@MainActor
struct ClipboardPasteboardTransaction {
    private struct Backup {
        let items: [[(String, Data)]]
        let changeCount: Int

        static let maximumItems = 64
        static let maximumRepresentations = 128
        static let maximumBytes = 4 * 1_024 * 1_024

        /// NSPasteboard returns materialized Data, so this limits retained bytes but can't cap one fetch's transient allocation.
        static func capture(from pasteboard: NSPasteboard) throws -> Backup {
            let changeCount = pasteboard.changeCount
            guard let pasteboardItems = pasteboard.pasteboardItems else {
                guard pasteboard.types?.isEmpty ?? true,
                      pasteboard.changeCount == changeCount
                else {
                    throw ImrseError.clipboardFailed
                }
                return Backup(items: [], changeCount: changeCount)
            }
            guard pasteboardItems.count <= maximumItems else { throw ImrseError.clipboardFailed }

            var totalRepresentations = 0
            var totalBytes = 0
            var items: [[(String, Data)]] = []
            for item in pasteboardItems {
                let types = item.types
                let (nextRepresentationCount, representationOverflow) = totalRepresentations.addingReportingOverflow(types.count)
                guard !types.isEmpty,
                      !representationOverflow,
                      nextRepresentationCount <= maximumRepresentations
                else {
                    throw ImrseError.clipboardFailed
                }
                totalRepresentations = nextRepresentationCount

                var representations: [(String, Data)] = []
                for type in types {
                    guard let data = item.data(forType: type) else { throw ImrseError.clipboardFailed }
                    let (nextByteCount, byteOverflow) = totalBytes.addingReportingOverflow(data.count)
                    guard !byteOverflow, nextByteCount <= maximumBytes else { throw ImrseError.clipboardFailed }
                    totalBytes = nextByteCount
                    representations.append((type.rawValue, data))
                }
                items.append(representations)
            }
            guard pasteboard.changeCount == changeCount else { throw ImrseError.clipboardFailed }
            return Backup(items: items, changeCount: changeCount)
        }

        func restore(to pasteboard: NSPasteboard) throws {
            _ = pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let restoredItems: [NSPasteboardWriting] = items.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                }
                return item
            }
            guard pasteboard.writeObjects(restoredItems) else { throw ImrseError.clipboardFailed }
        }
    }

    private static let markerTypePrefix = "com.imrse.private-paste-owner."
    private let backup: Backup
    private let markerType: NSPasteboard.PasteboardType
    private let markerData: Data
    private var ownedChangeCount: Int?
    private var stagedText: String?

    private init(backup: Backup, markerID: UUID) {
        self.backup = backup
        markerType = NSPasteboard.PasteboardType(Self.markerTypePrefix + markerID.uuidString)
        markerData = Data(markerID.uuidString.utf8)
    }

    static func capture(from pasteboard: NSPasteboard) throws -> ClipboardPasteboardTransaction {
        ClipboardPasteboardTransaction(backup: try Backup.capture(from: pasteboard), markerID: UUID())
    }

    mutating func stage(_ text: String, on pasteboard: NSPasteboard) throws {
        guard pasteboard.changeCount == backup.changeCount else { throw ImrseError.clipboardFailed }
        let clearedCount = pasteboard.clearContents()
        let (expectedClearCount, overflow) = backup.changeCount.addingReportingOverflow(1)
        guard !overflow, clearedCount == expectedClearCount, pasteboard.changeCount == clearedCount else {
            throw ImrseError.clipboardFailed
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(markerData, forType: markerType)
        let writeSucceeded = pasteboard.writeObjects([item])
        let writtenChangeCount = pasteboard.changeCount
        let markerMatches = pasteboard.data(forType: markerType) == markerData
        let items = pasteboard.pasteboardItems
        let singleMarkedItem = items?.count == 1
            && items?.first?.data(forType: markerType) == markerData
            && items?.first?.string(forType: .string) == text
        let countMatches = pasteboard.changeCount == writtenChangeCount
        if markerMatches, countMatches, singleMarkedItem {
            ownedChangeCount = writtenChangeCount
            stagedText = text
        }
        guard writeSucceeded, markerMatches, countMatches, singleMarkedItem else {
            throw ImrseError.clipboardFailed
        }
    }

    func stillOwns(_ pasteboard: NSPasteboard) -> Bool {
        guard let ownedChangeCount, pasteboard.changeCount == ownedChangeCount,
              pasteboard.data(forType: markerType) == markerData,
              let stagedText,
              pasteboard.pasteboardItems?.count == 1,
              pasteboard.pasteboardItems?.first?.string(forType: .string) == stagedText
        else {
            return false
        }
        return pasteboard.changeCount == ownedChangeCount
    }

    mutating func restoreIfOwned(on pasteboard: NSPasteboard) throws -> Bool {
        guard stillOwns(pasteboard) else { return false }
        try backup.restore(to: pasteboard)
        ownedChangeCount = nil
        stagedText = nil
        return true
    }
}
#endif
