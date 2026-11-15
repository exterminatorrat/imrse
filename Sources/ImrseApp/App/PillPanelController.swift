#if os(macOS)
import AppKit
import Combine
import ImrseMac
import ImrsePillCore
import ImrsePillUI
import SwiftUI

@MainActor
final class PillPanelController {
    static let panelStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    private let model: AppModel
    private var panel: ImrsePanel?
    private var keyMonitor: Any?
    private var subscription: AnyCancellable?
    private var capturedVisibleFrame: NSRect?
    private let presentationFocus = PillPresentationFocusSession()

    init(model: AppModel) {
        self.model = model
        subscription = model.pillModel.lifecycleChanges
            .sink { [weak self] lifecycle in
                guard let self else { return }
                let phase = lifecycle.phase
                guard phase.isVisible else { self.hide(); return }
                switch phase {
                case .success, .failure:
                    self.makeFeedbackNonKey()
                default:
                    break
                }
                self.presentationFocus.didChange(to: phase)
                self.resizePanel(for: PillTokens.width(for: phase))
            }
    }

    func present(afterCapturingTargetOn screen: NSScreen?) {
        guard model.pillModel.phase.isVisible else { return }
        let acceptsInputFocus = Self.acceptsInputFocus(for: model.pillModel.phase)
        if acceptsInputFocus {
            presentationFocus.begin(model.selectionAccess.presentationFocusReturn)
        }
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        guard let screen = screen ?? pointerScreen ?? NSScreen.main else { return }

        let visible = screen.visibleFrame
        capturedVisibleFrame = visible
        let panel = makePanelIfNeeded()
        panel.setFrame(Self.frame(width: PillTokens.width(for: model.pillModel.phase), visibleFrame: visible), display: false)
        model.selectionAccess.focusObservationPanelPhase = .presentationRequested
        if acceptsInputFocus {
            panel.acceptsKeyFocus = true
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
        } else {
            panel.acceptsKeyFocus = false
            panel.orderFrontRegardless()
        }
        model.selectionAccess.focusObservationPanelPhase = .presentationReturned
        installKeyMonitor()
    }

    func hideForFocusHandoff() {
        hide(forFocusHandoff: true)
    }

    static func acceptsInputFocus(for phase: PillPhase) -> Bool {
        phase == .input
    }

    func invalidatePresentationFocusReturn() {
        presentationFocus.invalidate()
    }

    private func makeFeedbackNonKey() {
        panel?.acceptsKeyFocus = false
        if let panel, panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    static func frame(width: CGFloat, visibleFrame: CGRect) -> CGRect {
        let padding = PillTokens.shadowPadding
        let cappedWidth = min(width, max(180, visibleFrame.width - 2 * PillTokens.edgeInset))
        let size = NSSize(width: cappedWidth + 2 * padding, height: PillTokens.height + 2 * padding)
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + PillTokens.bottomInset - padding,
            width: size.width,
            height: size.height
        )
    }

    private func resizePanel(for width: CGFloat) {
        guard let panel, let capturedVisibleFrame else { return }
        panel.setFrame(Self.frame(width: width, visibleFrame: capturedVisibleFrame), display: false)
    }

    private func makePanelIfNeeded() -> ImrsePanel {
        if let panel { return panel }
        let panel = ImrsePanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: PillTokens.width(for: .input) + 2 * PillTokens.shadowPadding, height: PillTokens.height + 2 * PillTokens.shadowPadding)
            ),
            styleMask: Self.panelStyleMask,
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
        let hostingView = NSHostingView(
            rootView: ImrsePillView(model: model.pillModel, hostHandlesEscape: true)
                .padding(PillTokens.shadowPadding)
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.initialFirstResponder = panel.contentView
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

    private func hide(forFocusHandoff: Bool = false) {
        model.selectionAccess.focusObservationPanelPhase = forFocusHandoff ? .handoffHideRequested : .hideRequested
        panel?.orderOut(nil)
        if !forFocusHandoff {
            panel?.acceptsKeyFocus = false
            presentationFocus.didChange(to: .hidden)
        }
        model.selectionAccess.focusObservationPanelPhase = forFocusHandoff ? .handoffHideReturned : .hideReturned
        capturedVisibleFrame = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

@MainActor
final class PillPresentationFocusSession {
    private var focusReturn: ApplicationFocusReturn?

    func begin(_ token: ApplicationFocusReturn?) {
        invalidate()
        focusReturn = token
    }

    func didChange(to phase: PillPhase) {
        switch phase {
        case .hidden, .success, .failure:
            let token = focusReturn
            focusReturn = nil
            token?.finishPresentation()
        default:
            break
        }
    }

    func invalidate() {
        let token = focusReturn
        focusReturn = nil
        token?.invalidate()
    }
}

private final class ImrsePanel: NSPanel {
    var acceptsKeyFocus = false
    override var canBecomeKey: Bool { acceptsKeyFocus }
    override var canBecomeMain: Bool { false }
}
#endif
