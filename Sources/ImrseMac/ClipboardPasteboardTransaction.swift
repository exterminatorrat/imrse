#if os(macOS)
import AppKit
import Foundation
import ImrseCore

public typealias ClipboardPastePreparation = @MainActor () async throws -> Void

@MainActor
struct ClipboardPasteboardTransaction {
    @MainActor
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

        func restore(
            to pasteboard: NSPasteboard,
            makeItem: @MainActor () -> NSPasteboardItem,
            verifyOwnership: () -> Bool,
            writeRestoredItems: @MainActor (NSPasteboard, [NSPasteboardItem]) -> Bool
        ) throws {
            let restoredItems: [NSPasteboardItem] = try items.map { representations in
                let item = makeItem()
                for (type, data) in representations {
                    let pasteboardType = NSPasteboard.PasteboardType(rawValue: type)
                    guard item.setData(data, forType: pasteboardType),
                          item.data(forType: pasteboardType) == data
                    else { throw ImrseError.clipboardFailed }
                }
                return item
            }
            let previousCount = pasteboard.changeCount
            guard verifyOwnership() else { throw ImrseError.clipboardFailed }
            let (expectedClearCount, overflow) = previousCount.addingReportingOverflow(1)
            guard !overflow else { throw ImrseError.clipboardFailed }
            let clearedCount = pasteboard.clearContents()
            guard clearedCount == expectedClearCount, pasteboard.changeCount == clearedCount else {
                throw ImrseError.clipboardFailed
            }
            guard !items.isEmpty else {
                guard pasteboard.types?.isEmpty ?? true, pasteboard.changeCount == clearedCount else {
                    throw ImrseError.clipboardFailed
                }
                return
            }
            guard writeRestoredItems(pasteboard, restoredItems) else { throw ImrseError.clipboardFailed }
            let restoredCount = pasteboard.changeCount
            guard let actualItems = pasteboard.pasteboardItems, actualItems.count == items.count else {
                throw ImrseError.clipboardFailed
            }
            for (actual, expected) in zip(actualItems, items) {
                guard actual.types.map(\.rawValue) == expected.map({ $0.0 }) else { throw ImrseError.clipboardFailed }
                for (type, data) in expected {
                    guard actual.data(forType: NSPasteboard.PasteboardType(rawValue: type)) == data else {
                        throw ImrseError.clipboardFailed
                    }
                }
            }
            guard pasteboard.changeCount == restoredCount else { throw ImrseError.clipboardFailed }
        }
    }

    private static let markerTypePrefix = "com.imrse.private-paste-owner."
    private let backup: Backup
    private let markerType: NSPasteboard.PasteboardType
    private let markerData: Data
    private let makeItem: @MainActor () -> NSPasteboardItem
    private var ownedChangeCount: Int?
    private var stagedText: String?
    private(set) var hasMutatedPasteboard = false

    private init(backup: Backup, markerID: UUID, makeItem: @escaping @MainActor () -> NSPasteboardItem) {
        self.backup = backup
        self.makeItem = makeItem
        markerType = NSPasteboard.PasteboardType(Self.markerTypePrefix + markerID.uuidString)
        markerData = Data(markerID.uuidString.utf8)
    }

    static func capture(
        from pasteboard: NSPasteboard,
        makeItem: @escaping @MainActor () -> NSPasteboardItem = { NSPasteboardItem() }
    ) throws -> ClipboardPasteboardTransaction {
        ClipboardPasteboardTransaction(backup: try Backup.capture(from: pasteboard), markerID: UUID(), makeItem: makeItem)
    }

    mutating func stage(_ text: String, on pasteboard: NSPasteboard) throws {
        let item = makeItem()
        guard item.setString(text, forType: .string),
              item.setData(markerData, forType: markerType),
              item.string(forType: .string) == text,
              item.data(forType: markerType) == markerData
        else {
            throw ImrseError.clipboardFailed
        }
        guard pasteboard.changeCount == backup.changeCount else { throw ImrseError.clipboardFailed }
        let (expectedClearCount, overflow) = backup.changeCount.addingReportingOverflow(1)
        guard !overflow else { throw ImrseError.clipboardFailed }
        hasMutatedPasteboard = true
        let clearedCount = pasteboard.clearContents()
        guard clearedCount == expectedClearCount, pasteboard.changeCount == clearedCount else {
            throw ImrseError.clipboardFailed
        }
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

    mutating func restoreIfOwned(
        on pasteboard: NSPasteboard,
        writeRestoredItems: @MainActor (NSPasteboard, [NSPasteboardItem]) -> Bool = { $0.writeObjects($1) }
    ) throws -> Bool {
        guard stillOwns(pasteboard) else { return false }
        let retained = backup
        try retained.restore(
            to: pasteboard,
            makeItem: makeItem,
            verifyOwnership: { stillOwns(pasteboard) },
            writeRestoredItems: writeRestoredItems
        )
        ownedChangeCount = nil
        stagedText = nil
        return true
    }
}

struct ClipboardDestinationIdentity: Equatable {
    let processID: Int32
    let launchDate: Date
    let executableURL: URL
    let applicationID: String

    func confirmsTermination(observed: Self?, isTerminated: Bool) -> Bool {
        isTerminated && observed == self
    }
}

@MainActor
final class ClipboardPasteRecovery<Transaction, Destination> {
    private struct Pending {
        var transaction: Transaction
        let destination: Destination
        let requiresConsumptionProof: Bool
    }

    private var pending: Pending?
    private var active = false

    var isBlocked: Bool { active || pending != nil }

    func recover(
        terminationConfirmed: (Destination) -> Bool,
        writeConfirmed: (Destination) throws -> Bool,
        restore: (inout Transaction) throws -> Bool
    ) throws {
        guard !active else { throw ImrseError.clipboardPending }
        guard var retained = pending else { return }
        guard !retained.requiresConsumptionProof
                || terminationConfirmed(retained.destination)
                || (try? writeConfirmed(retained.destination)) == true
        else {
            throw ImrseError.clipboardPending
        }
        do {
            guard try restore(&retained.transaction) else { throw ImrseError.clipboardPending }
        } catch {
            pending = retained
            throw ImrseError.clipboardPending
        }
        pending = nil
    }

    func perform<Output>(
        destination: Destination,
        capture: () throws -> Transaction,
        stage: (inout Transaction) throws -> Void,
        verify: (Transaction) throws -> Void,
        post: () -> Void,
        confirm: @MainActor () async throws -> Output,
        hasMutated: (Transaction) -> Bool,
        restore: (inout Transaction) throws -> Bool
    ) async throws -> Output {
        guard !isBlocked else { throw ImrseError.clipboardPending }
        active = true
        defer { active = false }
        var transaction = try capture()
        var dispatched = false
        var confirmed = false
        var restorationAttempted = false
        do {
            try stage(&transaction)
            try verify(transaction)
            try Task.checkCancellation()
            dispatched = true
            post()
            try Task.checkCancellation()
            let output = try await confirm()
            try Task.checkCancellation()
            confirmed = true
            restorationAttempted = true
            guard try restore(&transaction) else { throw ImrseError.clipboardPending }
            return output
        } catch {
            if hasMutated(transaction) {
                var restored = false
                if (!dispatched || confirmed) && !restorationAttempted {
                    restored = (try? restore(&transaction)) == true
                }
                if !restored {
                    pending = Pending(
                        transaction: transaction,
                        destination: destination,
                        requiresConsumptionProof: dispatched && !confirmed
                    )
                    throw ImrseError.clipboardPending
                }
            }
            throw error
        }
    }
}
#endif
