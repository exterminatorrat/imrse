#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Keeps the real macOS traffic lights while letting the content extend into the title-bar area,
/// matching the reference without drawing fake window chrome.
struct ImrseSettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: ImrseSettingsMetrics.windowWidth, height: ImrseSettingsMetrics.windowHeight))
        window.minSize = NSSize(width: ImrseSettingsMetrics.windowWidth, height: ImrseSettingsMetrics.windowHeight)
        window.maxSize = NSSize(width: ImrseSettingsMetrics.windowWidth, height: ImrseSettingsMetrics.windowHeight)
    }
}
#endif
