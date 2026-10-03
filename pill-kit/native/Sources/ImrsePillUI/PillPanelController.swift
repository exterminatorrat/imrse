import AppKit
import SwiftUI
import Combine
import ImrsePillCore

@MainActor
private final class PillPanel: NSPanel {
    var choosePreset: ((Int) -> Bool)?
    var dismissPill: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismissPill?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers, let n = Int(key), (1...9).contains(n) {
            if choosePreset?(n - 1) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Optional native host. Do not install a second panel if imrse already owns one.
/// Does not read Accessibility data, install global shortcuts, or mutate the clipboard.
@MainActor
public final class PillPanelController {
    public let model: PillModel
    private let panel: PillPanel
    private var subscription: AnyCancellable?

    public init(model: PillModel) {
        self.model = model
        panel = PillPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.choosePreset = { [weak model] index in
            guard let model, model.phase == .input, model.inputIsFocused, model.presets.indices.contains(index) else { return false }
            model.applyPreset(at: index)
            return true
        }
        panel.dismissPill = { [weak model] in model?.dismiss() }
        subscription = model.$lifecycle.sink { [weak panel] state in
            if !state.phase.isVisible { panel?.orderOut(nil) }
        }
        // Intentionally no orderFront call here. Construction must be completely invisible.
    }

    /// The caller MUST capture the source target before entering this method.
    /// Pass the captured application's screen to avoid a cross-display surprise.
    public func present(afterCapturingTargetOn screen: NSScreen? = nil) {
        guard model.phase.activeRequestID == nil else { return }
        if model.phase == .input {
            panel.orderFrontRegardless(); panel.makeKey()
            return // Preserve an existing instruction on a repeated invocation.
        }
        let targetScreen = screen ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let targetScreen else { return }
        let visible = targetScreen.visibleFrame
        let width = min(PillTokens.width, max(180, visible.width - 2 * PillTokens.edgeInset))
        let padding = PillTokens.shadowPadding
        let content = ImrsePillView(model: model, width: width)
            .padding(padding)
        panel.contentView = NSHostingView(rootView: content)
        panel.setFrame(NSRect(x: visible.midX - (width + padding * 2) / 2,
                              y: visible.minY + PillTokens.bottomInset - padding,
                              width: width + padding * 2, height: PillTokens.height + padding * 2), display: false)
        model.present()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    public func dismiss() { model.dismiss(); panel.orderOut(nil) }
}
