#if os(macOS)
import Foundation
import ImrseMac

enum PermissionAuthorizationStatus: Equatable {
    case allowed
    case notAuthorized
    case notQueried

    var title: String {
        switch self {
        case .allowed: "Allowed"
        case .notAuthorized: "Not authorized"
        case .notQueried: "Not queried"
        }
    }
}

enum KeyboardMonitoringActivity: Equatable {
    case active
    case pausedWhileRecording
    case inactive
    case unavailable
    case notQueried

    var title: String {
        switch self {
        case .active: "Active"
        case .pausedWhileRecording: "Paused while recording"
        case .inactive: "Inactive"
        case .unavailable: "Unavailable"
        case .notQueried: "Not queried"
        }
    }
}

struct PermissionStatusSnapshot: Equatable {
    var accessibility: PermissionAuthorizationStatus
    var inputMonitoring: PermissionAuthorizationStatus
    var keyboardMonitoring: KeyboardMonitoringActivity

    static let notQueried = Self(
        accessibility: .notQueried,
        inputMonitoring: .notQueried,
        keyboardMonitoring: .notQueried
    )
}

@MainActor
struct PermissionStatusReader {
    let accessibility: @MainActor () -> Bool
    let inputMonitoring: @MainActor () -> Bool

    static var system: Self {
        Self(
            accessibility: { MacSelectionAccess.accessibilityPermissionGranted },
            inputMonitoring: { ShortcutMonitor.eventMonitoringPermissionGranted }
        )
    }
}

@MainActor
struct PermissionStatusRefreshClock {
    let interval: Duration
    let sleep: @MainActor (Duration) async throws -> Void

    static let live = Self(interval: .seconds(2)) { duration in
        try await Task.sleep(for: duration)
    }
}
#endif
