#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Foundation
import CryptoKit

/// PAUSED, UNWIRED DRAFT: no production adapter constructs this type.
/// Requires native qualification and accessible explicit recovery before enabling.
/// Native Cmd-C transport for an independently pinned source. This is optimistic clipboard
/// ownership (version + every representation), not an atomic OS compare-and-swap.
@MainActor
final class NativeSelectionCopyHost: ExplicitSelectionCopyHost {
    private let target: ExplicitCopyTarget
    private let expectedSourceDigest: SHA256.Digest
    private let validate: () throws -> Void
    private let pasteboard: NSPasteboard
    private var dispatched = false

    init(target: ExplicitCopyTarget, expectedSource: String,
         pasteboard: NSPasteboard = .general, validate: @escaping () throws -> Void) {
        self.target = target; self.expectedSourceDigest = SHA256.hash(data: Data(expectedSource.utf8))
        self.pasteboard = pasteboard; self.validate = validate
    }

    func readClipboard(maximumBytes: Int) -> ExplicitCopyClipboardRead {
        let version = pasteboard.changeCount
        guard version >= 0 else { return .unavailable }
        guard let items = pasteboard.pasteboardItems else {
            guard pasteboard.types?.isEmpty ?? true, pasteboard.changeCount == version else { return .unavailable }
            return .snapshot(.init(version: version, items: [], acknowledgedCopyID: nil))
        }
        guard items.count <= 16 else { return .tooLarge }
        var bytes = 0
        var materialized: [[ExplicitCopyClipboardRepresentation]] = []
        for item in items {
            let types = item.types.sorted { $0.rawValue < $1.rawValue }
            guard !types.isEmpty, types.count <= 32 else { return .unsupported }
            var representations: [ExplicitCopyClipboardRepresentation] = []
            for type in types {
                // Do not initiate file-promise fulfilment as a side effect of copying text.
                guard !type.rawValue.lowercased().contains("promise"), type.rawValue.utf8.count <= 256 else { return .unsupported }
                guard let data = item.data(forType: type) else { return .unavailable }
                // NSPasteboard materializes Data; this bounds retained bytes, not one fetch's allocation.
                guard data.count <= maximumBytes - bytes else { return .tooLarge }
                bytes += data.count
                representations.append(.init(type: type.rawValue, data: data))
            }
            materialized.append(representations)
        }
        guard pasteboard.changeCount == version else { return .unavailable }
        return .snapshot(.init(version: version, items: materialized, acknowledgedCopyID: nil))
    }

    func dispatchCopyOnce(ifTargetMatches requested: ExplicitCopyTarget, operationID: UUID) -> ExplicitCopyDispatch {
        guard !dispatched, requested == target, !Task.isCancelled,
              MacSelectionAccess.eventPostingPermissionGranted,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { return .notDispatched }
        do { try validate() } catch { return .notDispatched }
        guard !Task.isCancelled else { return .notDispatched }
        dispatched = true
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(target.processID); up.postToPid(target.processID)
        return .dispatched
    }

    func verifyExpectedSource(_ source: String, for requested: ExplicitCopyTarget) -> Bool {
        guard requested == target, SHA256.hash(data: Data(source.utf8)) == expectedSourceDigest else { return false }
        do { try validate(); return true } catch { return false }
    }

    // An ordinary app's Cmd-C cannot issue a cooperating-host acknowledgment.
    func restoreBackup(_ backup: ExplicitCopyClipboardSnapshot,
                       onlyIfOwned current: ExplicitCopyClipboardSnapshot,
                       operationID: UUID) -> ExplicitCopyRestore { .uncertain }

    func restoreBackupOptimistically(_ backup: ExplicitCopyClipboardSnapshot,
                                     onlyIfCurrent current: ExplicitCopyClipboardSnapshot) -> ExplicitCopyRestore {
        guard backup.isBounded, current.isBounded else { return .uncertain }
        var restored: [NSPasteboardItem] = []
        for representations in backup.items {
            let item = NSPasteboardItem()
            for representation in representations {
                let type = NSPasteboard.PasteboardType(representation.type)
                guard item.setData(representation.data, forType: type),
                      item.data(forType: type) == representation.data else { return .uncertain }
            }
            restored.append(item)
        }
        guard case .snapshot(let latest) = readClipboard(maximumBytes: ExplicitSelectionCopy.maximumClipboardBytes),
              latest.sameClipboard(as: current) else { return .ownershipLost }
        // No await or target activation after the final ownership sample.
        let previous = pasteboard.changeCount
        guard previous == current.version, previous < Int.max else { return .ownershipLost }
        let cleared = pasteboard.clearContents()
        guard cleared == previous + 1, pasteboard.changeCount == cleared else { return .uncertain }
        if !restored.isEmpty, !pasteboard.writeObjects(restored) { return .uncertain }
        let completedVersion = pasteboard.changeCount
        guard case .snapshot(let actual) = readClipboard(maximumBytes: ExplicitSelectionCopy.maximumClipboardBytes),
              actual.version == completedVersion, actual.items == backup.items else { return .uncertain }
        return .restored
    }
}
#endif
