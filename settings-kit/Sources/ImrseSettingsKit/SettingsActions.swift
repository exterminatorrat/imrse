#if canImport(SwiftUI)
import Foundation

public struct ImrseSettingsActions {
    public var onChangeGlobalShortcut: () -> Void
    public var onChangePresetShortcut: (UUID) -> Void
    public var onStoreCredential: (UUID, String) -> Void
    public var onOpenConfigLocation: () -> Void
    public var onOpenLogs: () -> Void
    public var onCopyDiagnostics: (String) -> Void
    public var onOpenURL: (URL) -> Void

    public init(
        onChangeGlobalShortcut: @escaping () -> Void = {},
        onChangePresetShortcut: @escaping (UUID) -> Void = { _ in },
        onStoreCredential: @escaping (UUID, String) -> Void = { _, _ in },
        onOpenConfigLocation: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {},
        onCopyDiagnostics: @escaping (String) -> Void = { _ in },
        onOpenURL: @escaping (URL) -> Void = { _ in }
    ) {
        self.onChangeGlobalShortcut = onChangeGlobalShortcut
        self.onChangePresetShortcut = onChangePresetShortcut
        self.onStoreCredential = onStoreCredential
        self.onOpenConfigLocation = onOpenConfigLocation
        self.onOpenLogs = onOpenLogs
        self.onCopyDiagnostics = onCopyDiagnostics
        self.onOpenURL = onOpenURL
    }

    public static let noop = ImrseSettingsActions()
}
#endif
