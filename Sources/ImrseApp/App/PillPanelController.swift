#if os(macOS)
import AppKit
import Combine
import ImrsePillUI
import SwiftUI

@MainActor
final class PillPanelController {
    private let model: AppModel
    private var panel: ImrsePanel?
    private var keyMonitor: Any?
    private var subscription: AnyCancellable?
    private var capturedVisibleFrame: NSRect?
    private var capturedAnchorFrame: NSRect?
    private var restoringAfterFocusHandoff = false
    private var hostingView: NSHostingView<PillPanelContent>?

    init(model: AppModel) {
        self.model = model
        subscription = model.pillModel.lifecycleChanges
            .sink { [weak self] lifecycle in
                guard let self else { return }
                let phase = lifecycle.phase
                guard phase.isVisible else { self.hide(); return }
                self.resizePanel(width: PillTokens.width(for: phase), height: PillTokens.height(for: phase))
            }
    }

    func present(afterCapturingTargetOn screen: NSScreen?, selectionBounds: CGRect? = nil) {
        guard model.pillModel.phase.isVisible else { return }
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        guard let screen = screen ?? pointerScreen ?? NSScreen.main else { return }

        let visible = screen.visibleFrame
        let anchorFrame = restoringAfterFocusHandoff && capturedVisibleFrame == visible ? capturedAnchorFrame : nil
        restoringAfterFocusHandoff = false
        capturedVisibleFrame = visible
        let panel = makePanelIfNeeded()
        hostingView?.rootView = PillPanelContent(model: model.pillModel, width: Self.contentWidth(PillTokens.width, visibleFrame: visible))
        let frame = Self.frame(width: PillTokens.width(for: model.pillModel.phase), height: PillTokens.height(for: model.pillModel.phase), visibleFrame: visible, selectionBounds: selectionBounds, anchorFrame: anchorFrame)
        if anchorFrame == nil { capturedAnchorFrame = frame }
        panel.setFrame(frame, display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        installKeyMonitor()
    }

    func hideForFocusHandoff() {
        hide(preservingAnchor: true)
    }

    static func contentWidth(_ width: CGFloat, visibleFrame: CGRect) -> CGFloat {
        min(width, max(1, visibleFrame.width - 2 * (PillTokens.edgeInset + PillTokens.shadowPadding)))
    }

    static func frame(width: CGFloat, height: CGFloat = PillTokens.height, visibleFrame: CGRect, selectionBounds: CGRect? = nil, anchorFrame: CGRect? = nil) -> CGRect {
        let padding = PillTokens.shadowPadding
        let size = NSSize(width: Self.contentWidth(width, visibleFrame: visibleFrame) + 2 * padding, height: height + 2 * padding)
        let usable = visibleFrame.insetBy(dx: PillTokens.edgeInset, dy: PillTokens.edgeInset)
        var origin = CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + PillTokens.bottomInset)
        if let anchorFrame {
            origin = CGPoint(x: anchorFrame.maxX - size.width, y: anchorFrame.minY)
        } else if let selectionBounds,
                  selectionBounds.minX.isFinite, selectionBounds.minY.isFinite,
                  selectionBounds.width.isFinite, selectionBounds.height.isFinite,
                  selectionBounds.width > 0, selectionBounds.height > 0,
                  visibleFrame.intersects(selectionBounds) {
            origin = CGPoint(x: selectionBounds.midX - size.width / 2, y: selectionBounds.minY - 8 - height - padding)
            if origin.y < usable.minY {
                origin.y = selectionBounds.maxY + 8 - padding
            }
        }
        return NSRect(
            x: min(max(origin.x, usable.minX), max(usable.minX, usable.maxX - size.width)),
            y: min(max(origin.y, usable.minY), max(usable.minY, usable.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    private func resizePanel(width: CGFloat, height: CGFloat) {
        guard let panel, let capturedVisibleFrame else { return }
        panel.setFrame(Self.frame(width: width, height: height, visibleFrame: capturedVisibleFrame, anchorFrame: capturedAnchorFrame), display: false)
    }

    private func makePanelIfNeeded() -> ImrsePanel {
        if let panel { return panel }
        let panel = ImrsePanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: PillTokens.width(for: .input) + 2 * PillTokens.shadowPadding, height: PillTokens.height + 2 * PillTokens.shadowPadding)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        let hostingView = NSHostingView(rootView: PillPanelContent(model: model.pillModel, width: PillTokens.width))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.initialFirstResponder = panel.contentView
        self.hostingView = hostingView
        self.panel = panel
        return panel
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let panel = self.panel,
                  event.window?.windowNumber == panel.windowNumber
            else { return event }

            if event.keyCode == 53 {
                guard !Self.hasMarkedText(in: event.window) else { return event }
                self.model.escape()
                return nil
            }
            if [36, 76].contains(Int(event.keyCode)) {
                guard !Self.hasMarkedText(in: event.window) else { return event }
                if self.model.isProcessing { return nil }
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command,
               !Self.hasMarkedText(in: event.window),
               self.model.pillModel.phase == .input,
               self.model.pillModel.inputIsFocused,
               let characters = event.charactersIgnoringModifiers,
               let number = Int(characters),
               (1...9).contains(number) {
                return self.model.selectPillPreset(at: number - 1) ? nil : event
            }
            return event
        }
    }

    private static func hasMarkedText(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    private func hide(preservingAnchor: Bool = false) {
        panel?.orderOut(nil)
        restoringAfterFocusHandoff = preservingAnchor
        if !preservingAnchor {
            capturedVisibleFrame = nil
            capturedAnchorFrame = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private struct PillPanelContent: View {
    let model: PillModel
    let width: CGFloat

    var body: some View {
        ImrsePillView(model: model, width: width, hostHandlesEscape: true)
            .padding(PillTokens.shadowPadding)
    }
}

private final class ImrsePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
