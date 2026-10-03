#if os(macOS) && DEBUG
import AppKit
import Combine
import ImrseCore
import SwiftUI
import XCTest
@testable import ImrseApp

@MainActor
final class ReasoningEffortControlTests: XCTestCase {
    func testNativeMenuShowsOnlyAdvertisedEffortsAndUpdatesSelection() throws {
        let endpoint = URL(string: "https://example.com/v1")!
        let capabilities = ReasoningEffortCapabilities(
            endpoint: endpoint,
            model: "test-model",
            supportedEfforts: ["high", "medium", "low"],
            requestFormat: .chatCompletionsField,
            defaultEffort: "medium"
        )
        let selection = ReasoningEffortControlSelection()
        let hostingView = NSHostingView(rootView: ReasoningEffortControlHost(
            selection: selection,
            capabilities: capabilities
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 84),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        settle(hostingView)

        let menuButton = try XCTUnwrap(descendants(of: hostingView).compactMap { $0 as? NSPopUpButton }.first)
        let menu = try XCTUnwrap(menuButton.menu)
        let options = Array(menu.items.dropFirst())
        XCTAssertEqual(options.map(\.title), ["Provider default (medium)", "high", "medium", "low"])
        XCTAssertFalse(options.contains { $0.title == "xhigh" })

        let low = try XCTUnwrap(options.first { $0.title == "low" })
        XCTAssertTrue(try activate(low))
        XCTAssertEqual(selection.effort, "low")
        settle(hostingView)

        let updatedButton = try XCTUnwrap(descendants(of: hostingView).compactMap { $0 as? NSPopUpButton }.first)
        let defaultOption = try XCTUnwrap(updatedButton.menu?.items.dropFirst().first { $0.title == "Provider default (medium)" })
        XCTAssertTrue(try activate(defaultOption))
        XCTAssertNil(selection.effort)
        settle(hostingView)

        if let screenshotPath = ProcessInfo.processInfo.environment["IMRSE_REASONING_CONTROL_SCREENSHOT_PATH"] {
            let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            let outputURL = URL(fileURLWithPath: screenshotPath)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: outputURL)
        }
    }

    private func activate(_ item: NSMenuItem) throws -> Bool {
        let action = try XCTUnwrap(item.action)
        let target = try XCTUnwrap(item.target)
        return NSApplication.shared.sendAction(action, to: target, from: item)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class ReasoningEffortControlSelection: ObservableObject {
    @Published var effort: String? = "medium"
}

private struct ReasoningEffortControlHost: View {
    @ObservedObject var selection: ReasoningEffortControlSelection
    let capabilities: ReasoningEffortCapabilities

    var body: some View {
        ReasoningEffortControl(effort: $selection.effort, capabilities: capabilities)
            .padding(12)
            .frame(width: 560, height: 84)
    }
}
#endif
