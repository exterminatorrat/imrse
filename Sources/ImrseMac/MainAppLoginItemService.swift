#if os(macOS)
import ServiceManagement

public enum MainAppLoginItemStatus: Equatable, Sendable {
    case notFound
    case notRegistered
    case enabled
    case requiresApproval
    case unknown

    public enum Action: Equatable, Sendable {
        case register
        case unregister
    }

    public init(systemStatus: SMAppService.Status) {
        switch systemStatus {
        case .notFound: self = .notFound
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        @unknown default: self = .unknown
        }
    }

    public func action(requesting enabled: Bool) -> Action? {
        switch (self, enabled) {
        case (.notRegistered, true): .register
        case (.enabled, false): .unregister
        default: nil
        }
    }
}

@MainActor
public enum MainAppLoginItemService {
    public static var status: MainAppLoginItemStatus {
        MainAppLoginItemStatus(systemStatus: SMAppService.mainApp.status)
    }

    public static func setEnabled(_ enabled: Bool) throws -> MainAppLoginItemStatus {
        let currentStatus = status
        guard let action = currentStatus.action(requesting: enabled) else { return currentStatus }

        switch action {
        case .register: try SMAppService.mainApp.register()
        case .unregister: try SMAppService.mainApp.unregister()
        }

        return status
    }

    public static func recoverFromNotFound() throws -> MainAppLoginItemStatus {
        try recoveryResult(
            from: status,
            register: { try SMAppService.mainApp.register() },
            readStatus: { status }
        )
    }

    static func recoveryResult(
        from currentStatus: MainAppLoginItemStatus,
        register: @MainActor () throws -> Void,
        readStatus: @MainActor () -> MainAppLoginItemStatus
    ) throws -> MainAppLoginItemStatus {
        guard currentStatus == .notFound else { return currentStatus }
        try register()
        return readStatus()
    }

    public static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
