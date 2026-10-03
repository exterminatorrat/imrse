#if os(macOS)
import AppKit

@MainActor
@main
enum ImrseApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = ImrseAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ImrseAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
        #if DEBUG
        coordinator.presentSettingsPreviewIfNeeded()
        #endif
        if !coordinator.model.isPreviewMode, !coordinator.model.configuration.showInMenuBar {
            coordinator.openSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.model.applicationDidBecomeActive()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        coordinator.openSettings()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        coordinator.contextMenu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator.model.requestTermination { reply in
            sender.reply(toApplicationShouldTerminate: reply == .terminateNow)
        }
    }
}
#endif
